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
    var gain: Float                 // manual input gain applied to L/R before plotting
    var sensitivity: Float          // auto-level amount: 0 = off (manual gain), 1 = full auto
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
        sensitivity: 0.5,
        exposure: 1.35,
        vignette: 0.55,
        pitchRotation: 0.0
    )
}

extension ScopeSettings {
    // Tolerant decoding: any field missing from an older saved blob falls back to
    // its default, so adding a new setting never wipes the user's saved ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScopeSettings.default
        beamColor         = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .beamColor) ?? d.beamColor
        intensity         = try c.decodeIfPresent(Float.self, forKey: .intensity) ?? d.intensity
        glow              = try c.decodeIfPresent(Float.self, forKey: .glow) ?? d.glow
        afterglowHalfLife = try c.decodeIfPresent(Float.self, forKey: .afterglowHalfLife) ?? d.afterglowHalfLife
        lineWidth         = try c.decodeIfPresent(Float.self, forKey: .lineWidth) ?? d.lineWidth
        gain              = try c.decodeIfPresent(Float.self, forKey: .gain) ?? d.gain
        sensitivity       = try c.decodeIfPresent(Float.self, forKey: .sensitivity) ?? d.sensitivity
        exposure          = try c.decodeIfPresent(Float.self, forKey: .exposure) ?? d.exposure
        vignette          = try c.decodeIfPresent(Float.self, forKey: .vignette) ?? d.vignette
        pitchRotation     = try c.decodeIfPresent(Float.self, forKey: .pitchRotation) ?? d.pitchRotation
    }
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
