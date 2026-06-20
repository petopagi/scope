//
//  ScopeMTKView.swift
//  SwiftUI bridge to an MTKView driven by the renderer at 60 fps.
//

import MetalKit
import SwiftUI

struct MetalScopeView: NSViewRepresentable {
    let renderer: ScopeRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.delegate = renderer
        // Prime the textures at the initial size.
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
        // Always take all the space SwiftUI offers, so the scope fills the window.
        nil
    }
}
