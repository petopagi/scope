//
//  Shaders.metal
//  Phosphor oscilloscope render passes:
//    beam (additive, soft round beam) → afterglow decay → bloom → composite.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Fullscreen triangle

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
    // Covers the screen with a single oversized triangle.
    float2 p = float2((vid << 1) & 2, vid & 2); // (0,0) (2,0) (0,2)
    FSOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// MARK: - Beam

struct BeamInOut {
    float4 position [[position]];
    float  edge;
    float  brightness;
};

vertex BeamInOut beamVertex(uint vid [[vertex_id]],
                            constant BeamVertex *verts   [[buffer(BeamBufferVertices)]],
                            constant BeamUniforms &u     [[buffer(BeamBufferUniforms)]]) {
    BeamVertex v = verts[vid];
    float2 ndc = float2(v.position.x / u.viewportSize.x * 2.0 - 1.0,
                        1.0 - v.position.y / u.viewportSize.y * 2.0);
    BeamInOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.edge = v.edge;
    out.brightness = v.brightness;
    return out;
}

fragment float4 beamFragment(BeamInOut in [[stage_in]]) {
    // Gaussian profile across the beam width → soft, round-edged trace.
    float a = exp(-in.edge * in.edge * 4.0);
    float i = in.brightness * a;
    return float4(i, i, i, i); // white energy; tinted later, additive blend
}

// MARK: - Afterglow decay

fragment float4 decayFragment(FSOut in [[stage_in]],
                              texture2d<float> prev [[texture(0)]],
                              constant float &decay [[buffer(0)]]) {
    return prev.sample(linearSampler, in.uv) * decay;
}

// MARK: - Bloom

fragment float4 brightPassFragment(FSOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   constant float &threshold [[buffer(0)]]) {
    float4 c = src.sample(linearSampler, in.uv);
    float lum = max(max(c.r, c.g), c.b);
    float keep = max(0.0, lum - threshold);
    return c * (keep / max(lum, 1e-4));
}

fragment float4 blurFragment(FSOut in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             constant float2 &dir [[buffer(0)]]) {
    const float w0 = 0.227027, w1 = 0.194595, w2 = 0.121622, w3 = 0.054054, w4 = 0.016216;
    float3 sum = src.sample(linearSampler, in.uv).rgb * w0;
    sum += src.sample(linearSampler, in.uv + dir * 1.0).rgb * w1;
    sum += src.sample(linearSampler, in.uv - dir * 1.0).rgb * w1;
    sum += src.sample(linearSampler, in.uv + dir * 2.0).rgb * w2;
    sum += src.sample(linearSampler, in.uv - dir * 2.0).rgb * w2;
    sum += src.sample(linearSampler, in.uv + dir * 3.0).rgb * w3;
    sum += src.sample(linearSampler, in.uv - dir * 3.0).rgb * w3;
    sum += src.sample(linearSampler, in.uv + dir * 4.0).rgb * w4;
    sum += src.sample(linearSampler, in.uv - dir * 4.0).rgb * w4;
    return float4(sum, 1.0);
}

// MARK: - Composite (tint, overexposure tone-map, vignette)

fragment float4 compositeFragment(FSOut in [[stage_in]],
                                  texture2d<float> accum [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]],
                                  constant CompositeUniforms &u [[buffer(0)]]) {
    float3 energy = accum.sample(linearSampler, in.uv).rgb
                  + bloom.sample(linearSampler, in.uv).rgb * u.bloomStrength;

    // Tint white energy with the phosphor colour, scaled by master intensity.
    float3 tinted = energy * u.beamColor.rgb * u.beamColor.a;

    // Filmic-ish exposure: bright regions saturate and bleed toward white.
    float3 mapped = 1.0 - exp(-tinted * u.exposure);

    // White-hot core where energy massively overexposes.
    float over = max(max(tinted.r, tinted.g), tinted.b);
    mapped += saturate(over - 1.0) * 0.6;

    // Subtle CRT vignette.
    float2 d = in.uv - 0.5;
    float vig = 1.0 - u.vignette * dot(d, d) * 2.0;
    mapped *= max(vig, 0.0);

    return float4(mapped, 1.0);
}
