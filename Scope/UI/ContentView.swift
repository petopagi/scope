//
//  ContentView.swift
//  Mostly the scope; the control panel floats on top and toggles with H.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                MetalScopeView(renderer: renderer).ignoresSafeArea()
            } else {
                Text("Metal is unavailable on this system.")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.showControls {
                ControlPanel()
                    .padding(18)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.showControls = true }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(18)
                .help("Show controls (press H)")
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: ["h", " "]) { _ in
            withAnimation(.easeInOut(duration: 0.18)) { model.showControls.toggle() }
            return .handled
        }
        .onAppear {
            focused = true
            // Auto-start on system audio so the scope is live immediately
            // (this is what triggers the audio-capture permission prompt).
            model.start()
        }
        .onDisappear { model.stop() }
    }
}
