//
//  ScopeApp.swift
//  App entry point. One fullscreen-capable window that is mostly the scope.
//

import SwiftUI

@main
struct ScopeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 520)
                .background(.black)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Toggle Controls") { model.showControls.toggle() }
                    .keyboardShortcut("h", modifiers: [])
                Button(model.isCapturing ? "Stop Capture" : "Start Capture") { model.toggleCapture() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
        }
    }
}
