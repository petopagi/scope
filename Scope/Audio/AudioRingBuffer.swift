//
//  AudioRingBuffer.swift
//  Lock-free single-producer / single-consumer ring of interleaved stereo
//  float frames.
//
//  Producer  = the real-time Core Audio IOProc thread (writes).
//  Consumer  = the 60 fps render loop (reads the most recent window).
//
//  The producer only ever advances `writeIndex` (published with a release
//  store); the consumer only advances `readIndex`. No locks, no allocation in
//  the hot path. If the consumer ever falls more than a whole buffer behind
//  (it never should at 60 fps) the oldest samples are simply skipped — exactly
//  what you want for a real-time visualiser.
//

import Foundation

final class AudioRingBuffer {
    /// Frames = stereo sample pairs. Storage holds `capacityFrames * 2` floats.
    let capacityFrames: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex: UnsafeMutablePointer<Int64>   // shared, atomic
    private var readIndex: Int64 = 0                       // consumer-owned

    init(capacityFrames requested: Int = 1 << 15) {        // 32768 frames ≈ 0.68 s @48k
        var cap = 1
        while cap < requested { cap <<= 1 }                // round up to power of two
        capacityFrames = cap
        mask = cap - 1
        storage = .allocate(capacity: cap * 2)
        storage.initialize(repeating: 0, count: cap * 2)
        writeIndex = .allocate(capacity: 1)
        writeIndex.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        writeIndex.deallocate()
    }

    // MARK: Producer (real-time thread — no allocation / locks / ARC)

    /// Interleaved source, taking the first two channels of each frame.
    /// `stride` is channels-per-frame (2 for plain stereo).
    func writeInterleavedStereo(_ src: UnsafePointer<Float>, stride: Int, frames: Int) {
        var w = rt_atomic_load_acquire(writeIndex)
        for i in 0..<frames {
            let slot = (Int(w) & mask) << 1
            let base = i * stride
            storage[slot]     = src[base]
            storage[slot + 1] = src[base + 1]
            w += 1
        }
        rt_atomic_store_release(writeIndex, w)
    }

    /// Separate (non-interleaved) channel pointers.
    func writePlanar(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, frames: Int) {
        var w = rt_atomic_load_acquire(writeIndex)
        for i in 0..<frames {
            let slot = (Int(w) & mask) << 1
            storage[slot]     = left[i]
            storage[slot + 1] = right[i]
            w += 1
        }
        rt_atomic_store_release(writeIndex, w)
    }

    /// Mono source duplicated to both channels (degenerate, draws a diagonal).
    func writeMono(_ mono: UnsafePointer<Float>, frames: Int) {
        var w = rt_atomic_load_acquire(writeIndex)
        for i in 0..<frames {
            let slot = (Int(w) & mask) << 1
            let v = mono[i]
            storage[slot]     = v
            storage[slot + 1] = v
            w += 1
        }
        rt_atomic_store_release(writeIndex, w)
    }

    // MARK: Consumer (render thread)

    /// Copy up to `maxFrames` of the most recent frames into `out` (interleaved),
    /// then mark everything consumed. Returns the number of frames written.
    @discardableResult
    func read(into out: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let w = rt_atomic_load_acquire(writeIndex)
        var available = Int(w - readIndex)
        if available <= 0 { return 0 }
        if available > capacityFrames { available = capacityFrames } // overflowed → keep newest

        let n = min(available, maxFrames)
        let start = w - Int64(n)                               // newest n frames
        for i in 0..<n {
            let slot = (Int(start + Int64(i)) & mask) << 1
            out[i << 1]       = storage[slot]
            out[(i << 1) + 1] = storage[slot + 1]
        }
        readIndex = w
        return n
    }
}
