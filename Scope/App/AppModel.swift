//
//  AppModel.swift
//  Owns the audio ring, capture engine and renderer, and exposes the live
//  controls to SwiftUI.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    // Sources / capture
    @Published var sources: [AudioSource] = []
    @Published var selectedSourceID: String = AudioSource.systemWide.id
    @Published private(set) var isCapturing = false
    @Published var status: String = "Ready"
    @Published var permissionLikelyDenied = false

    // UI
    @Published var showControls = true { didSet { persist() } }

    // When true, the captured audio is silenced (the app makes no sound).
    @Published var muted = true {
        didSet { if isCapturing { start() }; persist() }   // re-tap to apply the new mute behaviour
    }

    // Tunables
    @Published var colorPreset: ColorPreset = .warm {
        didSet { settings.beamColor = colorPreset.rgb; persist() }
    }
    @Published var settings = ScopeSettings.default {
        didSet { renderer?.settings = settings; persist() }
    }

    let ring = AudioRingBuffer()
    let renderer: ScopeRenderer?
    private let capture: ProcessTapCapture
    private var suppressPersist = false

    init() {
        let renderer = ScopeRenderer(ring: ring)
        self.renderer = renderer
        self.capture = ProcessTapCapture(ring: ring)
        loadPersisted()                 // restore saved settings before anything reads them
        renderer?.settings = settings
        refreshSources()
    }

    // MARK: Persistence

    private enum Key {
        static let settings = "scope.settings"
        static let color = "scope.colorPreset"
        static let muted = "scope.muted"
        static let source = "scope.sourceID"
        static let controls = "scope.showControls"
    }

    private func persist() {
        guard !suppressPersist else { return }
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(settings) { d.set(data, forKey: Key.settings) }
        d.set(colorPreset.rawValue, forKey: Key.color)
        d.set(muted, forKey: Key.muted)
        d.set(selectedSourceID, forKey: Key.source)
        d.set(showControls, forKey: Key.controls)
    }

    private func loadPersisted() {
        let d = UserDefaults.standard
        suppressPersist = true
        defer { suppressPersist = false }
        if let data = d.data(forKey: Key.settings),
           let saved = try? JSONDecoder().decode(ScopeSettings.self, from: data) {
            settings = saved
        }
        if let raw = d.string(forKey: Key.color), let preset = ColorPreset(rawValue: raw) {
            colorPreset = preset
        }
        if d.object(forKey: Key.muted) != nil { muted = d.bool(forKey: Key.muted) }
        if let src = d.string(forKey: Key.source) { selectedSourceID = src }
        if d.object(forKey: Key.controls) != nil { showControls = d.bool(forKey: Key.controls) }
    }

    // MARK: Sources

    func refreshSources() {
        sources = AudioProcessEnumerator.sources()
        if !sources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = AudioSource.systemWide.id
        }
    }

    func selectSource(_ id: String) {
        selectedSourceID = id
        persist()
        if isCapturing { start() }   // hot-swap the source
    }

    // MARK: Capture

    func start() {
        guard let source = sources.first(where: { $0.id == selectedSourceID }) ?? sources.first else {
            status = "No audio source available"
            return
        }
        do {
            try capture.start(source: source, muted: muted)
            isCapturing = true
            renderer?.sampleRate = capture.sampleRate
            permissionLikelyDenied = false
            status = "Capturing \(source.name) · \(Int(capture.sampleRate)) Hz"
        } catch {
            isCapturing = false
            permissionLikelyDenied = true
            status = "Couldn't start capture: \(error.localizedDescription)"
        }
    }

    func stop() {
        capture.stop()
        isCapturing = false
        status = "Stopped"
    }

    func toggleCapture() {
        isCapturing ? stop() : start()
    }

    func openPrivacySettings() {
        // Audio-capture consent lives under Privacy & Security.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
