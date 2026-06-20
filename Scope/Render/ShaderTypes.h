//
//  ShaderTypes.h
//  Types shared between Swift (via the bridging header) and the Metal shaders.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Buffer binding indices.
typedef enum {
    BeamBufferVertices = 0,
    BeamBufferUniforms = 1,
} BeamBufferIndex;

// One expanded beam-quad vertex, built on the CPU each frame.
typedef struct {
    vector_float2 position;   // drawable pixel coordinates
    float         edge;       // -1..1 across the line width (soft falloff)
    float         brightness; // inverse-velocity weighted intensity
} BeamVertex;

typedef struct {
    vector_float2 viewportSize; // drawable size in pixels
} BeamUniforms;

typedef struct {
    vector_float4 beamColor;    // rgb tint, a = master intensity
    float bloomStrength;
    float exposure;
    float vignette;
    float _pad;
} CompositeUniforms;

#endif /* ShaderTypes_h */
