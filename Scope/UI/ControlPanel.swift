//
//  ControlPanel.swift
//  Minimal translucent control surface: source picker, transport, colour and
//  the live beam tunables.
//

import SwiftUI

struct ControlPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sourceRow
            Divider().opacity(0.3)
            colorRow
            slidersGroup
            statusRow
        }
        .padding(16)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.path.ecg.rectangle")
            Text("Scope").font(.headline)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { model.showControls = false }
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Hide controls (press H)")
        }
    }

    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCE").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { model.selectedSourceID },
                    set: { model.selectSource($0) }
                )) {
                    ForEach(model.sources) { source in
                        HStack {
                            if let icon = source.icon {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                            Text(source.name + (source.isPlaying && source.id != "system" ? " ♪" : ""))
                        }
                        .tag(source.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Button { model.refreshSources() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh source list")

                Button { model.toggleCapture() } label: {
                    Image(systemName: model.isCapturing ? "stop.fill" : "play.fill")
                        .frame(width: 16)
                }
                .help(model.isCapturing ? "Stop" : "Start")
            }
            Toggle(isOn: $model.muted) {
                Text("Silent (mute captured audio)").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.orange)
        }
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BEAM COLOUR").font(.caption2).foregroundStyle(.secondary)
            Picker("", selection: $model.colorPreset) {
                ForEach(ColorPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var slidersGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Intensity", value: $model.settings.intensity, range: 0.05...1.5)
            slider("Glow", value: $model.settings.glow, range: 0...3)
            slider("Afterglow", value: $model.settings.afterglowHalfLife, range: 0.01...0.6, suffix: "s")
            slider("Line width", value: $model.settings.lineWidth, range: 0.6...6)
            slider("Gain", value: $model.settings.gain, range: 0.2...6)
            slider("Sensitivity", value: $model.settings.sensitivity, range: 0...1)
            slider("Pitch spin", value: $model.settings.pitchRotation, range: 0...2, suffix: "×")
        }
    }

    private func slider(_ label: String, value: Binding<Float>, range: ClosedRange<Float>, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue) + suffix)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.status)
                .font(.caption2)
                .foregroundStyle(model.permissionLikelyDenied ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.permissionLikelyDenied {
                Button("Open Privacy Settings") { model.openPrivacySettings() }
                    .font(.caption2)
            }
        }
    }
}
