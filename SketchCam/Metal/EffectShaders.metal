#include <metal_stdlib>
using namespace metal;

// GPU replacements for the CoreImage effect chain — basic building blocks:
// threshold, Sobel outline, morphology (dilate/erode), box blur, composite.
// All write premultiplied BGRA into an IOSurface-backed output texture.

constant float3 kLuma = float3(0.299, 0.587, 0.114);

// Vector fields first so Swift `MemoryLayout` matches without manual padding.
struct ThresholdParams {
    float2 inSize;       // input pixel size (for aspect-fill)
    float2 outSize;      // output pixel size
    float threshold;     // luminance cutoff 0..1
    uint invert;         // flip ink/paper
    uint inkOnly;        // paper → transparent, keep only ink strokes
};

struct OutlineParams {
    float2 inSize;
    float2 outSize;
    float4 color;        // straight-alpha stroke color
    float strength;      // edge sensitivity
};

// Aspect-fill: map an output pixel to input normalized UV (input centered,
// scaled to cover the output).
static float2 aspectFillUV(uint2 gid, float2 inSize, float2 outSize) {
    float scale = max(outSize.x / inSize.x, outSize.y / inSize.y);
    float2 scaled = inSize * scale;
    float2 offset = (outSize - scaled) * 0.5;
    return (float2(gid) - offset) / scaled;
}

kernel void effect_threshold(texture2d<float, access::sample> inTex [[texture(0)]],
                             texture2d<float, access::write> outTex [[texture(1)]],
                             constant ThresholdParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 c = inTex.sample(s, aspectFillUV(gid, p.inSize, p.outSize));
    float luma = dot(c.rgb, kLuma);
    float paper = luma > p.threshold ? 1.0 : 0.0;     // 1 = bright/paper, 0 = ink
    if (p.invert == 1u) paper = 1.0 - paper;
    if (p.inkOnly == 1u) {
        float a = (paper < 0.5) ? 1.0 : 0.0;           // keep only ink, paper clear
        outTex.write(float4(0.0, 0.0, 0.0, a), gid);   // premultiplied black
    } else {
        outTex.write(float4(float3(paper), 1.0), gid); // opaque B/W
    }
}

// Sobel edge magnitude of luminance → colored stroke on transparent.
kernel void effect_outline(texture2d<float, access::sample> inTex [[texture(0)]],
                           texture2d<float, access::write> outTex [[texture(1)]],
                           constant OutlineParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 px = 1.0 / p.outSize;   // one output pixel in UV
    float2 uv = aspectFillUV(gid, p.inSize, p.outSize);
    float l00 = dot(inTex.sample(s, uv + float2(-px.x, -px.y)).rgb, kLuma);
    float l10 = dot(inTex.sample(s, uv + float2(0.0, -px.y)).rgb, kLuma);
    float l20 = dot(inTex.sample(s, uv + float2(px.x, -px.y)).rgb, kLuma);
    float l01 = dot(inTex.sample(s, uv + float2(-px.x, 0.0)).rgb, kLuma);
    float l21 = dot(inTex.sample(s, uv + float2(px.x, 0.0)).rgb, kLuma);
    float l02 = dot(inTex.sample(s, uv + float2(-px.x, px.y)).rgb, kLuma);
    float l12 = dot(inTex.sample(s, uv + float2(0.0, px.y)).rgb, kLuma);
    float l22 = dot(inTex.sample(s, uv + float2(px.x, px.y)).rgb, kLuma);
    float gx = (l20 + 2.0 * l21 + l22) - (l00 + 2.0 * l01 + l02);
    float gy = (l02 + 2.0 * l12 + l22) - (l00 + 2.0 * l10 + l20);
    float mag = clamp(length(float2(gx, gy)) * p.strength, 0.0, 1.0);
    float a = mag * p.color.a;
    outTex.write(float4(p.color.rgb * a, a), gid);     // premultiplied
}

struct MorphParams { int radius; uint dilate; };       // dilate=1 max, 0 min (erode)

kernel void effect_morphology(texture2d<float, access::read> inTex [[texture(0)]],
                              texture2d<float, access::write> outTex [[texture(1)]],
                              constant MorphParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    uint w = outTex.get_width(), h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 acc = inTex.read(gid);
    for (int dy = -p.radius; dy <= p.radius; ++dy) {
        for (int dx = -p.radius; dx <= p.radius; ++dx) {
            int2 c = int2(gid) + int2(dx, dy);
            if (c.x < 0 || c.y < 0 || c.x >= int(w) || c.y >= int(h)) continue;
            float4 s = inTex.read(uint2(c));
            acc = (p.dilate == 1u) ? max(acc, s) : min(acc, s);
        }
    }
    outTex.write(acc, gid);
}

struct BlurParams { int radius; };

kernel void effect_box_blur(texture2d<float, access::read> inTex [[texture(0)]],
                            texture2d<float, access::write> outTex [[texture(1)]],
                            constant BlurParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    uint w = outTex.get_width(), h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 sum = float4(0.0);
    int count = 0;
    for (int dy = -p.radius; dy <= p.radius; ++dy) {
        for (int dx = -p.radius; dx <= p.radius; ++dx) {
            int2 c = int2(gid) + int2(dx, dy);
            if (c.x < 0 || c.y < 0 || c.x >= int(w) || c.y >= int(h)) continue;
            sum += inTex.read(uint2(c));
            count++;
        }
    }
    outTex.write(count > 0 ? sum / float(count) : inTex.read(gid), gid);
}

// Source-over: premultiplied overlay onto premultiplied base.
kernel void effect_composite(texture2d<float, access::read> baseTex [[texture(0)]],
                             texture2d<float, access::read> overlayTex [[texture(1)]],
                             texture2d<float, access::write> outTex [[texture(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float4 b = baseTex.read(gid);
    float4 o = overlayTex.read(gid);
    outTex.write(o + b * (1.0 - o.a), gid);
}

// Source-over with a layer opacity (premultiplied overlay scaled by opacity)
// and common straight-colour blend modes.
struct CompositeParams { float opacity; uint blendMode; };
static float soft_light_channel(float b, float o) {
    if (o <= 0.5) return b - (1.0 - 2.0 * o) * b * (1.0 - b);
    float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
    return b + (2.0 * o - 1.0) * (d - b);
}
static float3 blend_color(float3 b, float3 o, uint mode) {
    switch (mode) {
        case 1: return b * o;                                      // multiply
        case 2: return 1.0 - (1.0 - b) * (1.0 - o);                // screen
        case 3: return min(b + o, 1.0);                            // add
        case 4: return mix(2.0 * b * o, 1.0 - 2.0 * (1.0 - b) * (1.0 - o), step(0.5, b));
        case 5: return min(b, o);                                  // darken
        case 6: return max(b, o);                                  // lighten
        case 7: return abs(b - o);                                 // difference
        case 8: return max(b - o, 0.0);                            // subtract
        case 9: return float3(soft_light_channel(b.r, o.r), soft_light_channel(b.g, o.g), soft_light_channel(b.b, o.b));
        default: return o;                                         // normal / unsupported HSL modes
    }
}
kernel void effect_composite_op(texture2d<float, access::read> baseTex [[texture(0)]],
                                texture2d<float, access::read> overlayTex [[texture(1)]],
                                texture2d<float, access::write> outTex [[texture(2)]],
                                constant CompositeParams &p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float4 b = baseTex.read(gid);
    float4 o = overlayTex.read(gid) * p.opacity;   // premultiplied scale
    if (p.blendMode == 0u || o.a <= 0.0) {
        outTex.write(o + b * (1.0 - o.a), gid);
        return;
    }
    float3 bRGB = b.a > 0.0 ? clamp(b.rgb / b.a, 0.0, 1.0) : float3(0.0);
    float3 oRGB = clamp(o.rgb / max(o.a, 1e-6), 0.0, 1.0);
    float3 blended = blend_color(bRGB, oRGB, p.blendMode);
    float outA = o.a + b.a * (1.0 - o.a);
    float3 outRGB = blended * o.a + b.rgb * (1.0 - o.a);
    outTex.write(float4(outRGB, outA), gid);
}

// Invert colour (premultiplied-aware): un-premultiply, 1−rgb, re-premultiply.
kernel void effect_invert(texture2d<float, access::read> inTex [[texture(0)]],
                          texture2d<float, access::write> outTex [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float4 c = inTex.read(gid);
    float3 rgb = c.a > 0.0 ? c.rgb / c.a : c.rgb;
    rgb = 1.0 - rgb;
    outTex.write(float4(rgb * c.a, c.a), gid);
}

// Mirror horizontally (flip x).
kernel void effect_mirror(texture2d<float, access::read> inTex [[texture(0)]],
                          texture2d<float, access::write> outTex [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint w = outTex.get_width();
    if (gid.x >= w || gid.y >= outTex.get_height()) return;
    outTex.write(inTex.read(uint2(w - 1 - gid.x, gid.y)), gid);
}

// Silhouette: fill the person matte region with a flat colour (ignores the
// layer content). invert flips which side is filled. Premultiplied output.
struct SilhouetteParams { float4 color; uint invert; };
kernel void effect_silhouette(texture2d<float, access::read> matteTex [[texture(0)]],
                              texture2d<float, access::write> outTex [[texture(1)]],
                              constant SilhouetteParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float4 ms = matteTex.read(gid);
    float m = dot(ms.rgb, kLuma) * ms.a;
    if (p.invert == 1u) m = 1.0 - m;
    float a = m * p.color.a;
    outTex.write(float4(p.color.rgb * a, a), gid);
}

// Apply a matte (from another stream) to a layer's content. mode: 0=luma,
// 1=threshold, 2=invThreshold; invert flips the final matte. Premultiplied
// content is scaled by the matte value, masking both colour and alpha.
struct MaskParams { float level; uint mode; uint invert; };
kernel void effect_mask(texture2d<float, access::read> contentTex [[texture(0)]],
                        texture2d<float, access::read> matteTex [[texture(1)]],
                        texture2d<float, access::write> outTex [[texture(2)]],
                        constant MaskParams &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float4 c = contentTex.read(gid);
    float4 msrc = matteTex.read(gid);
    float luma = dot(msrc.rgb, kLuma);
    float m;
    if (p.mode == 1u) m = luma >= p.level ? 1.0 : 0.0;
    else if (p.mode == 2u) m = luma <  p.level ? 1.0 : 0.0;
    else m = luma * msrc.a;                 // luma mode also respects matte alpha
    if (p.invert == 1u) m = 1.0 - m;
    outTex.write(c * m, gid);               // premultiplied scale
}
