//
//  ScopeSettings.swift
//  Live, user-tunable parameters read by the renderer each frame.
//  Codable so they can be persisted across launches.
//

import simd

struct ScopeSettings: Equatable, Codable {
    var beamColor: SIMD3<Float>     // phosphor tint (rgb)
    var intensity: Float            // master beam intensity
    var glow: Float                 // bloom strength
    var afterglowHalfLife: Float    // seconds for the trail to halve
    var lineWidth: Float            // beam thickness in points
    var gain: Float                 // input gain applied to L/R before plotting
    var exposure: Float             // overexposure tone-map strength
    var vignette: Float             // CRT vignette amount
    var pitchRotation: Float        // turns-per-octave the figure rotates by detected pitch (0 = off)

    static let `default` = ScopeSettings(
        beamColor: ColorPreset.warm.rgb,
        intensity: 0.55,
        glow: 1.15,
        afterglowHalfLife: 0.085,
        lineWidth: 2.2,
        gain: 1.5,
        exposure: 1.35,
        vignette: 0.55,
        pitchRotation: 0.0
    )
}

enum ColorPreset: String, CaseIterable, Identifiable {
    case warm  = "Warm"
    case green = "Green"
    case amber = "Amber"
    case ice   = "Ice"

    var id: String { rawValue }

    var rgb: SIMD3<Float> {
        switch self {
        case .warm:  return SIMD3(1.00, 0.40, 0.16)  // sosci-style red/orange
        case .green: return SIMD3(0.32, 1.00, 0.45)  // classic P1 phosphor
        case .amber: return SIMD3(1.00, 0.72, 0.20)  // P3 amber
        case .ice:   return SIMD3(0.42, 0.78, 1.00)  // cool blue
        }
    }
}
