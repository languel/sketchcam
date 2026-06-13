#include <metal_stdlib>
using namespace metal;

// Interleaved vertex layout from StrokeTessellator: 6 floats per vertex
// (x, y, r, g, b, a). Positions are in canvas PIXELS, origin BOTTOM-left, y-UP
// (matching the overlay's CGContext convention: higher y = visually higher).
// The viewport uniform maps them to NDC.

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut line_vertex(uint vid [[vertex_id]],
                             const device float *verts [[buffer(0)]],
                             constant float2 &viewport [[buffer(1)]]) {
    uint base = vid * 6u;
    float2 p = float2(verts[base + 0], verts[base + 1]);
    float4 c = float4(verts[base + 2], verts[base + 3], verts[base + 4], verts[base + 5]);

    // y-up: canvas y = viewport.y maps to NDC +1 (row 0 / visual top),
    // matching the CGContext overlay so the two composite identically.
    float2 ndc = float2((p.x / viewport.x) * 2.0 - 1.0,
                        (p.y / viewport.y) * 2.0 - 1.0);

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = c;
    return out;
}

fragment float4 line_fragment(VertexOut in [[stage_in]]) {
    // Premultiplied output, paired with (one, oneMinusSourceAlpha) blending for
    // correct source-over compositing into a premultiplied BGRA target.
    return float4(in.color.rgb * in.color.a, in.color.a);
}
