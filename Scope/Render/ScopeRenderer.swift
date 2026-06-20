//
//  ScopeRenderer.swift
//  Drives the X/Y phosphor pipeline at the display refresh rate, decoupled from
//  the audio callback (it only drains the ring buffer).
//
//  Per frame:
//    1. Afterglow  — previous accumulation × decay → current accumulation.
//    2. Beam       — upsample new audio, build soft additive line quads.
//    3. Bloom      — bright-pass + separable Gaussian (half-res).
//    4. Composite  — tint, overexposure tone-map, vignette → drawable.
//

import Metal
import MetalKit
import simd
import QuartzCore

final class ScopeRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    private let queue: MTLCommandQueue

    // Pipelines
    private var beamPipeline: MTLRenderPipelineState!
    private var decayPipeline: MTLRenderPipelineState!
    private var brightPipeline: MTLRenderPipelineState!
    private var blurPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!

    // Persistent HDR accumulation (ping-pong) + bloom work textures.
    private var accumA: MTLTexture?
    private var accumB: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var pingPong = false
    private var drawableSize: CGSize = .zero
    private var bloomSize: CGSize = .zero
    private let colorFormat: MTLPixelFormat = .bgra8Unorm

    // Triple-buffered beam vertex storage.
    private let maxInFlight = 3
    private var vertexBuffers: [MTLBuffer] = []
    private let inFlight = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    private let maxVertices: Int

    // Audio drain + geometry scratch.
    let ring: AudioRingBuffer
    private let maxInputFrames = 2048
    private let maxSubdiv = 8
    private var scratch: UnsafeMutablePointer<Float>
    private var px: [Float]
    private var py: [Float]
    private var lastL: Float = 0
    private var lastR: Float = 0
    private var hasLast = false

    // Pitch → rotation analysis.
    private let analysisSize = 2048
    private var analysisBuf: UnsafeMutablePointer<Float>
    private var analysisHasData = false
    private var currentAngle: Float = 0
    private let pitchRefHz: Float = 261.63    // C4 → the figure's untilted orientation
    private let twoPi: Float = 2 * .pi

    // Live state.
    var settings = ScopeSettings.default
    var sampleRate: Double = 48_000
    private let subdivisions = 6              // Catmull-Rom segments between samples
    private var backingScale: Float = 2       // points → pixels (updated from the view)
    private var levelSmooth: Float = 0.3      // tracked signal peak, for auto-level (Sensitivity)
    private var lastTime = CACurrentMediaTime()

    init?(ring: AudioRingBuffer) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.ring = ring

        maxVertices = maxInputFrames * maxSubdiv * 6 + 64
        scratch = .allocate(capacity: maxInputFrames * 2)
        scratch.initialize(repeating: 0, count: maxInputFrames * 2)
        analysisBuf = .allocate(capacity: analysisSize)
        analysisBuf.initialize(repeating: 0, count: analysisSize)
        px = [Float](repeating: 0, count: maxInputFrames + 2)
        py = [Float](repeating: 0, count: maxInputFrames + 2)

        super.init()

        do {
            try buildPipelines()
        } catch {
            NSLog("Scope: pipeline build failed: \(error)")
            return nil
        }

        for _ in 0..<maxInFlight {
            guard let buf = device.makeBuffer(length: maxVertices * MemoryLayout<BeamVertex>.stride,
                                              options: .storageModeShared) else { return nil }
            vertexBuffers.append(buf)
        }
    }

    deinit {
        scratch.deallocate()
        analysisBuf.deallocate()
    }

    // MARK: Pipeline construction

    private func buildPipelines() throws {
        guard let library = device.makeDefaultLibrary() else {
            throw NSError(domain: "Scope", code: -1, userInfo: [NSLocalizedDescriptionKey: "no default.metallib"])
        }
        let hdr: MTLPixelFormat = .rgba16Float

        func make(_ vfn: String, _ ffn: String, _ format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vfn)
            desc.fragmentFunction = library.makeFunction(name: ffn)
            let att = desc.colorAttachments[0]!
            att.pixelFormat = format
            if additive {
                att.isBlendingEnabled = true
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                att.sourceRGBBlendFactor = .one
                att.sourceAlphaBlendFactor = .one
                att.destinationRGBBlendFactor = .one
                att.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        beamPipeline      = try make("beamVertex", "beamFragment", hdr, additive: true)
        decayPipeline     = try make("fullscreenVertex", "decayFragment", hdr, additive: false)
        brightPipeline    = try make("fullscreenVertex", "brightPassFragment", hdr, additive: false)
        blurPipeline      = try make("fullscreenVertex", "blurFragment", hdr, additive: false)
        compositePipeline = try make("fullscreenVertex", "compositeFragment", colorFormat, additive: false)
    }

    // MARK: Sizing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        allocateTextures(size: size)
    }

    private func allocateTextures(size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        drawableSize = size
        bloomSize = CGSize(width: max(1, size.width / 2), height: max(1, size.height / 2))

        func tex(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                             width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        accumA = tex(Int(size.width), Int(size.height))
        accumB = tex(Int(size.width), Int(size.height))
        bloomA = tex(Int(bloomSize.width), Int(bloomSize.height))
        bloomB = tex(Int(bloomSize.width), Int(bloomSize.height))
        clearAccumulation()
    }

    private func clearAccumulation() {
        guard let a = accumA, let b = accumB,
              let cb = queue.makeCommandBuffer() else { return }
        for t in [a, b] {
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = t
            pd.colorAttachments[0].loadAction = .clear
            pd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pd.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pd)?.endEncoding()
        }
        cb.commit()
    }

    // MARK: Draw

    func draw(in view: MTKView) {
        guard drawableSize.width >= 1,
              let accumA, let accumB, let bloomA, let bloomB,
              let drawable = view.currentDrawable,
              let finalPass = view.currentRenderPassDescriptor else { return }

        if let scale = view.window?.backingScaleFactor { backingScale = Float(scale) }

        inFlight.wait()
        guard let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        cb.addCompletedHandler { [inFlight] _ in inFlight.signal() }

        // Afterglow decay factor from the tunable half-life.
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 1.0 / 240.0), 1.0 / 15.0))
        lastTime = now
        let halfLife = max(settings.afterglowHalfLife, 0.004)
        let decay = pow(Float(0.5), dt / halfLife)

        let prev = pingPong ? accumB : accumA
        let cur  = pingPong ? accumA : accumB

        // 1. Decay previous accumulation into current.
        encodeFullscreen(cb, pipeline: decayPipeline, target: cur, load: .dontCare) { enc in
            enc.setFragmentTexture(prev, index: 0)
            var d = decay
            enc.setFragmentBytes(&d, length: MemoryLayout<Float>.size, index: 0)
        }

        // 2. Beam — additive over the decayed accumulation.
        let vertexBuffer = vertexBuffers[frameIndex % maxInFlight]
        let vertexCount = buildBeamGeometry(into: vertexBuffer, dt: dt)
        if vertexCount > 0 {
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = cur
            pd.colorAttachments[0].loadAction = .load
            pd.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: pd) {
                enc.setRenderPipelineState(beamPipeline)
                enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)   // BeamBufferVertices
                var u = BeamUniforms(viewportSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)))
                enc.setVertexBytes(&u, length: MemoryLayout<BeamUniforms>.stride, index: 1)   // BeamBufferUniforms
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
                enc.endEncoding()
            }
        }

        // 3. Bloom — bright pass + separable blur at half resolution.
        encodeFullscreen(cb, pipeline: brightPipeline, target: bloomA, load: .dontCare) { enc in
            enc.setFragmentTexture(cur, index: 0)
            var threshold: Float = 0.55
            enc.setFragmentBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
        }
        let spread: Float = 1.5
        encodeFullscreen(cb, pipeline: blurPipeline, target: bloomB, load: .dontCare) { enc in
            enc.setFragmentTexture(bloomA, index: 0)
            var dir = SIMD2<Float>(spread / Float(bloomSize.width), 0)
            enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        encodeFullscreen(cb, pipeline: blurPipeline, target: bloomA, load: .dontCare) { enc in
            enc.setFragmentTexture(bloomB, index: 0)
            var dir = SIMD2<Float>(0, spread / Float(bloomSize.height))
            enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }

        // 4. Composite to the drawable.
        if let enc = cb.makeRenderCommandEncoder(descriptor: finalPass) {
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentTexture(cur, index: 0)
            enc.setFragmentTexture(bloomA, index: 1)
            var cu = CompositeUniforms(
                beamColor: SIMD4(settings.beamColor.x, settings.beamColor.y, settings.beamColor.z, settings.intensity),
                bloomStrength: settings.glow,
                exposure: settings.exposure,
                vignette: settings.vignette,
                _pad: 0)
            enc.setFragmentBytes(&cu, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
        pingPong.toggle()
        frameIndex &+= 1
    }

    private func encodeFullscreen(_ cb: MTLCommandBuffer,
                                  pipeline: MTLRenderPipelineState,
                                  target: MTLTexture,
                                  load: MTLLoadAction,
                                  _ setup: (MTLRenderCommandEncoder) -> Void) {
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = target
        pd.colorAttachments[0].loadAction = load
        pd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pd) else { return }
        enc.setRenderPipelineState(pipeline)
        setup(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: Beam geometry (CPU)

    /// Drains the ring, upsamples (Catmull-Rom) and writes expanded line quads
    /// straight into the vertex buffer. Returns the vertex count.
    private func buildBeamGeometry(into buffer: MTLBuffer, dt: Float) -> Int {
        let frames = ring.read(into: scratch, maxFrames: maxInputFrames)
        updateAnalysis(frameCount: frames)

        let n = buildXYPoints(frames: frames, dt: dt)
        guard n >= 2 else { return 0 }

        let vb = buffer.contents().bindMemory(to: BeamVertex.self, capacity: maxVertices)
        var count = 0
        let halfW = max(settings.lineWidth, 0.5) * backingScale * 0.5
        let speedRef = max(halfW, 1.0) * 1.6
        let subdiv = max(1, min(subdivisions, maxSubdiv))

        var prev = SIMD2<Float>(px[0], py[0])
        var i = 0
        while i < n - 1 {
            let p1 = SIMD2<Float>(px[i], py[i])
            let p2 = SIMD2<Float>(px[i + 1], py[i + 1])
            let p0 = i > 0 ? SIMD2<Float>(px[i - 1], py[i - 1]) : p1
            let p3 = (i + 2 < n) ? SIMD2<Float>(px[i + 2], py[i + 2]) : p2

            var s = 1
            while s <= subdiv {
                let t = Float(s) / Float(subdiv)
                let cur = catmullRom(p0, p1, p2, p3, t)
                if count + 6 > maxVertices { return count }
                emitQuad(vb, &count, prev, cur, halfW, speedRef)
                prev = cur
                s += 1
            }
            i += 1
        }
        return count
    }

    // MARK: Point builder

    /// X/Y Lissajous: plot (x = L, y = R), optionally rotated by the detected
    /// pitch. Returns the point count written to px/py.
    private func buildXYPoints(frames: Int, dt: Float) -> Int {
        updateRotation(dt: dt)
        let rc = cosf(currentAngle)
        let rs = sinf(currentAngle)
        let w = Float(drawableSize.width)
        let h = Float(drawableSize.height)
        // Fill the whole window: X spans the full width, Y the full height.
        let hw = w * 0.5
        let hh = h * 0.5
        let cx = hw, cy = hh

        // Auto-level (Sensitivity): track the signal peak with a fast attack /
        // slow release, then steer the trace toward a target fill. The slider
        // crossfades between manual gain (0) and full auto-level (1).
        if frames > 0 {
            var peak: Float = 0
            var fp = 0
            while fp < frames {
                let a = abs(scratch[fp << 1])
                let b = abs(scratch[(fp << 1) + 1])
                if a > peak { peak = a }
                if b > peak { peak = b }
                fp += 1
            }
            let k: Float = peak > levelSmooth ? 0.35 : 0.04
            levelSmooth += (peak - levelSmooth) * k
        }
        let autoGain = simd_clamp(0.7 / max(levelSmooth, 0.03), 0.3, 25)
        let g = settings.gain * (1 + (autoGain - 1) * simd_clamp(settings.sensitivity, 0, 1))

        var n = 0
        if hasLast {
            let l = lastL * g, r = lastR * g
            px[0] = cx + clampUnit(l * rc - r * rs) * hw
            py[0] = cy - clampUnit(l * rs + r * rc) * hh
            n = 1
        }
        var f = 0
        while f < frames && n < px.count {
            let l = scratch[f << 1] * g
            let r = scratch[(f << 1) + 1] * g
            px[n] = cx + clampUnit(l * rc - r * rs) * hw
            py[n] = cy - clampUnit(l * rs + r * rc) * hh
            n += 1
            f += 1
        }
        if frames > 0 {
            lastL = scratch[(frames - 1) << 1]
            lastR = scratch[((frames - 1) << 1) + 1]
            hasLast = true
        }
        return n
    }

    // MARK: Pitch tracking → rotation

    /// Slide the newest mono samples into the analysis window (a shift register).
    private func updateAnalysis(frameCount: Int) {
        guard frameCount > 0 else { return }
        let take = min(frameCount, analysisSize)
        if take < analysisSize {
            memmove(analysisBuf, analysisBuf + take, (analysisSize - take) * MemoryLayout<Float>.size)
        }
        let startFrame = frameCount - take
        var dst = analysisSize - take
        var i = 0
        while i < take {
            let f = startFrame + i
            analysisBuf[dst] = 0.5 * (scratch[f << 1] + scratch[(f << 1) + 1])
            dst += 1
            i += 1
        }
        analysisHasData = true
    }

    /// Map the detected pitch to a target angle and ease toward it (shortest path).
    private func updateRotation(dt: Float) {
        let turns = settings.pitchRotation
        var target = currentAngle
        if turns <= 0.0001 {
            target = 0
        } else if analysisHasData {
            let pitch = detectPitch(sr: Float(sampleRate))
            if pitch > 0 {
                target = twoPi * turns * log2f(pitch / pitchRefHz)
            }
        }
        let diff = atan2f(sinf(target - currentAngle), cosf(target - currentAngle))
        let tau: Float = 0.06
        let k = 1 - expf(-dt / max(tau, 1e-3))
        currentAngle += diff * k
        currentAngle = atan2f(sinf(currentAngle), cosf(currentAngle))   // keep bounded
    }

    /// Autocorrelation pitch estimate over the analysis window. Returns 0 when
    /// there's no confident periodicity (silence / noise) so the angle holds.
    private func detectPitch(sr: Float) -> Float {
        let n = analysisSize
        let buf = analysisBuf
        var energy: Float = 1e-6
        var i = 0
        while i < n { let v = buf[i]; energy += v * v; i += 1 }
        if energy < 1e-2 { return 0 }   // effectively silent

        let minLag = max(2, Int(sr / 1600))
        let maxLag = min(n - 2, Int(sr / 45))
        guard maxLag > minLag + 2 else { return 0 }

        func corr(_ lag: Int) -> Float {
            var sum: Float = 0
            let m = n - lag
            var j = 0
            while j < m { sum += buf[j] * buf[j + lag]; j += 1 }
            return sum / energy
        }

        var bestLag = -1
        var bestCorr: Float = 0
        var lag = minLag
        while lag <= maxLag {
            let c = corr(lag)
            if c > bestCorr { bestCorr = c; bestLag = lag }
            lag += 1
        }
        guard bestLag > minLag, bestCorr > 0.35 else { return 0 }

        // Parabolic interpolation for sub-sample (smooth) period estimate.
        let y0 = corr(bestLag - 1)
        let y1 = bestCorr
        let y2 = corr(bestLag + 1)
        let denom = y0 - 2 * y1 + y2
        let delta: Float = abs(denom) > 1e-6 ? 0.5 * (y0 - y2) / denom : 0
        let refined = Float(bestLag) + delta
        return refined > 0 ? sr / refined : 0
    }

    @inline(__always)
    private func emitQuad(_ vb: UnsafeMutablePointer<BeamVertex>, _ count: inout Int,
                          _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ halfW: Float, _ speedRef: Float) {
        let delta = b - a
        let len = simd_length(delta)
        let dir = len > 1e-4 ? delta / len : SIMD2<Float>(1, 0)
        let nrm = SIMD2<Float>(-dir.y, dir.x)
        let nOff = nrm * halfW
        let ext = dir * halfW            // cap extension so adjacent quads overlap at joins

        // Inverse-velocity brightness: slow beam (short segment) = brighter.
        let bright = settings.intensity * simd_clamp(speedRef / (len + 0.5), 0.04, 6.0)

        let a0 = a - nOff - ext
        let a1 = a + nOff - ext
        let b0 = b - nOff + ext
        let b1 = b + nOff + ext

        vb[count + 0] = BeamVertex(position: a0, edge: -1, brightness: bright)
        vb[count + 1] = BeamVertex(position: a1, edge:  1, brightness: bright)
        vb[count + 2] = BeamVertex(position: b1, edge:  1, brightness: bright)
        vb[count + 3] = BeamVertex(position: a0, edge: -1, brightness: bright)
        vb[count + 4] = BeamVertex(position: b1, edge:  1, brightness: bright)
        vb[count + 5] = BeamVertex(position: b0, edge: -1, brightness: bright)
        count += 6
    }

    @inline(__always)
    private func catmullRom(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>,
                            _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
        let t2 = t * t
        let t3 = t2 * t
        let c0: SIMD2<Float> = 2.0 * p1
        let c1: SIMD2<Float> = (p2 - p0) * t
        let c2: SIMD2<Float> = (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
        let c3: SIMD2<Float> = (3.0 * p1 - 3.0 * p2 + p3 - p0) * t3
        return 0.5 * (c0 + c1 + c2 + c3)
    }

    @inline(__always)
    private func clampUnit(_ v: Float) -> Float { min(max(v, -1), 1) }
}
