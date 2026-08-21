#include <metal_stdlib>
using namespace metal;

// GPU replacements for the CoreImage effect chain — basic building blocks:
// threshold, Sobel outline, morphology (dilate/erode), box blur, composite.
// All write premultiplied BGRA into an IOSurface-backed output texture.

constant float3 kLuma = float3(0.299, 0.587, 0.114);

struct OpticalFlowParams { float gain; };
struct LevelsParams {
    float blackPoint;
    float whitePoint;
    float gamma;
    float gain;
    float softClip;
};
struct DuotoneParams {
    float4 shadowTint;
    float4 highlightTint;
    float strength;
    float blackPoint;
    float whitePoint;
    float gamma;
    uint invert;
};
struct PatternParams {
    float scale;       // cell/stripe period in pixels
    float thickness;   // dot or stripe width in pixels
    float strength;    // tonal contrast / effect blend
    float angle;       // stripe angle in radians
    float softness;    // edge softness (also rounds pixel dots)
    float sampling;    // local feature/luminance sampling amount
    float variationScale; // longitudinal stripe variation scale
    float dotResponse; // dot size response to tone/features (0 constant, 1 proportional)
    float stripeResponse; // stripe width response (0 flat, 1 baseline, >1 exaggerated)
    float stripeBleed; // permitted overlap beyond one stripe period
    uint invert;       // invert luminance before quantising
    uint transparentBackground;
    float4 foregroundTint;
    float4 backgroundTint;
};

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
        float a = ((paper < 0.5) ? 1.0 : 0.0) * c.a;   // keep only ink, paper clear
        outTex.write(float4(0.0, 0.0, 0.0, a), gid);   // premultiplied black
    } else {
        outTex.write(float4(float3(paper) * c.a, c.a), gid);
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

// Lightweight dense optical-flow visualization using a one-step
// brightness-constancy estimate. Direction is encoded in red/green and speed
// in brightness/blue, making the result useful as both a visible layer and a
// downstream luminance mask.
kernel void effect_optical_flow(texture2d<float, access::sample> current [[texture(0)]],
                                texture2d<float, access::sample> previous [[texture(1)]],
                                texture2d<float, access::write> outTex [[texture(2)]],
                                constant OpticalFlowParams &p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(outTex.get_width(), outTex.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float2 texel = 1.0 / size;
    auto lum = [&](texture2d<float, access::sample> tex, float2 q) {
        float4 c = tex.sample(s, q);
        return dot(c.rgb, kLuma);
    };
    float gx = 0.5 * (lum(current, uv + float2(texel.x, 0.0)) - lum(current, uv - float2(texel.x, 0.0)));
    float gy = 0.5 * (lum(current, uv + float2(0.0, texel.y)) - lum(current, uv - float2(0.0, texel.y)));
    float gt = lum(current, uv) - lum(previous, uv);
    float denom = gx * gx + gy * gy + 0.0015;
    float2 flow = clamp(-gt * float2(gx, gy) / denom, -1.0, 1.0);
    float magnitude = clamp(length(flow) * max(0.0, p.gain), 0.0, 1.0);
    float3 encoded = float3(0.5 + 0.5 * flow.x, 0.5 + 0.5 * flow.y, 1.0) * magnitude;
    outTex.write(float4(encoded, magnitude), gid);
}

kernel void effect_levels(texture2d<float, access::read> inTex [[texture(0)]],
                          texture2d<float, access::write> outTex [[texture(1)]],
                          constant LevelsParams &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float4 c = inTex.read(gid);
    float3 rgb = c.a > 1e-5 ? c.rgb / c.a : c.rgb;
    float span = max(0.001, p.whitePoint - p.blackPoint);
    rgb = clamp((rgb - p.blackPoint) / span, 0.0, 1.0);
    rgb = pow(rgb, float3(1.0 / max(0.01, p.gamma)));
    // Gain expands or compresses around middle gray. Soft clip adds a
    // smooth shoulder at both extremes instead of a binary threshold.
    rgb = clamp((rgb - 0.5) * max(0.01, p.gain) + 0.5, 0.0, 1.0);
    float shoulder = clamp(p.softClip, 0.0, 1.0) * 0.45;
    float3 softened = smoothstep(float3(shoulder),
                                 float3(1.0 - shoulder), rgb);
    rgb = mix(rgb, softened, clamp(p.softClip, 0.0, 1.0));
    outTex.write(float4(rgb * c.a, c.a), gid);
}

// A smooth two-colour tonal remap. It preserves the source alpha so it can be
// layered over paper or other transparent effects without creating a matte.
kernel void effect_duotone(texture2d<float, access::read> inTex [[texture(0)]],
                           texture2d<float, access::write> outTex [[texture(1)]],
                           constant DuotoneParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float4 c = inTex.read(gid);
    float3 rgb = c.a > 1e-5 ? c.rgb / c.a : c.rgb;
    float span = max(0.001, p.whitePoint - p.blackPoint);
    float tone = clamp((dot(rgb, kLuma) - p.blackPoint) / span, 0.0, 1.0);
    tone = pow(tone, 1.0 / max(0.01, p.gamma));
    if (p.invert == 1u) tone = 1.0 - tone;
    float3 mapped = mix(p.shadowTint.rgb, p.highlightTint.rgb, tone);
    rgb = mix(rgb, mapped, max(0.0, p.strength));
    outTex.write(float4(rgb * c.a, c.a), gid);
}

// The pattern passes deliberately stay local and deterministic: source
// cells jitter by a stable hash and sample nearby luminance/features, so they
// do not shimmer as the camera moves. Marks use explicit ink/paper tints and
// can leave the paper transparent for compositing over another layer.
static float patternTone(float3 rgb, uint invert) {
    float tone = 1.0 - dot(rgb, kLuma); // dark source -> more ink
    return invert == 1u ? 1.0 - tone : tone;
}

static float2 patternHash2(float2 p) {
    return fract(sin(float2(dot(p, float2(127.1, 311.7)),
                            dot(p, float2(269.5, 183.3)))) * 43758.5453);
}

// Keep fine scales precise, then gently widen the response above the knee so
// the coarse end of the slider does not feel compressed. Numeric values above
// the UI range continue through this curve instead of being clipped.
static float patternCellScale(float raw) {
    float scale = max(2.0, raw);
    constexpr float knee = 12.0;
    if (scale <= knee) return scale;
    return knee + pow(scale - knee, 1.10);
}

static float4 patternComposite(float mark, float4 source, constant PatternParams &p) {
    float sourceAlpha = clamp(source.a, 0.0, 1.0);
    float foregroundAlpha = sourceAlpha * clamp(p.foregroundTint.a * mark, 0.0, 1.0);
    float backgroundAlpha = p.transparentBackground == 1u
        ? 0.0
        : sourceAlpha * clamp(p.backgroundTint.a, 0.0, 1.0);
    float outAlpha = foregroundAlpha + backgroundAlpha * (1.0 - foregroundAlpha);
    float3 outRGB = p.foregroundTint.rgb * foregroundAlpha
        + p.backgroundTint.rgb * backgroundAlpha * (1.0 - foregroundAlpha);
    return float4(outRGB, outAlpha);
}

static float patternToneAt(texture2d<float, access::sample> tex,
                            sampler s, float2 point, float2 size, uint invert) {
    float4 sample = tex.sample(s, point / size);
    // Camera and composited layers are premultiplied. Read the straight colour
    // for analysis so transparent edges do not become artificial dark ink.
    float3 rgb = sample.a > 1e-5 ? sample.rgb / sample.a : sample.rgb;
    return patternTone(rgb, invert);
}

// Candidate positions for the independent blue-noise pass. One candidate per
// cell is enough to keep the shader bounded; the rank/spacing gate below turns
// this jittered lattice into a progressive Poisson-like prefix.
static float2 blueNoiseCenter(float2 cellID, float cell) {
    float2 h = patternHash2(cellID + float2(97.13, 43.71));
    return (cellID + 0.5) * cell + (h - 0.5) * cell * 0.84;
}

static float blueNoiseRank(float2 cellID) {
    // A second hash decorrelates ordering from the position jitter. The same
    // rank is used for every frame, so changing luminance only reveals/hides a
    // stable subset instead of making particles crawl.
    return patternHash2(cellID + float2(211.7, 83.9)).x;
}

static bool blueNoiseAccepted(float2 cellID, float2 center, float cell,
                              float sampling) {
    float rank = blueNoiseRank(cellID);
    float minimumDistance = cell * mix(0.42, 0.82, sampling);
    // The radius is below one cell at the normal settings, but a 5x5 search
    // keeps the guarantee intact when the user enters a larger sampling value.
    for (int oy = -2; oy <= 2; ++oy) {
        for (int ox = -2; ox <= 2; ++ox) {
            if (ox == 0 && oy == 0) continue;
            float2 neighbourID = cellID + float2(ox, oy);
            if (blueNoiseRank(neighbourID) >= rank) continue;
            float2 neighbour = blueNoiseCenter(neighbourID, cell);
            if (length(center - neighbour) < minimumDistance) return false;
        }
    }
    return true;
}

// A fresh, feature-aware blue-noise stippler. It follows the same useful
// property as the reference progressive Poisson list: low-density renders are
// prefixes of a well-spaced point order. Tone controls the broad mass of ink,
// while the local gradient term allocates extra points to eyes, mouths, edges,
// and other high-frequency detail.
kernel void effect_blue_noise_stipple(texture2d<float, access::sample> inTex [[texture(0)]],
                                      texture2d<float, access::write> outTex [[texture(1)]],
                                      constant PatternParams &p [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(outTex.get_width(), outTex.get_height());
    float2 pos = float2(gid) + 0.5;
    float cell = patternCellScale(p.scale);
    float2 cellID = floor(pos / cell);
    float mark = 0.0;
    float sampleRadius = max(1.0, cell * mix(0.32, 1.25, p.sampling));

    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            float2 candidateID = cellID + float2(ox, oy);
            float2 center = blueNoiseCenter(candidateID, cell);
            if (!blueNoiseAccepted(candidateID, center, cell, p.sampling)) continue;

            float tone = patternToneAt(inTex, s, center, size, p.invert);
            float toneL = patternToneAt(inTex, s, center + float2(-sampleRadius, 0), size, p.invert);
            float toneR = patternToneAt(inTex, s, center + float2(sampleRadius, 0), size, p.invert);
            float toneU = patternToneAt(inTex, s, center + float2(0, -sampleRadius), size, p.invert);
            float toneD = patternToneAt(inTex, s, center + float2(0, sampleRadius), size, p.invert);
            float toneUL = patternToneAt(inTex, s, center + float2(-sampleRadius, -sampleRadius), size, p.invert);
            float toneUR = patternToneAt(inTex, s, center + float2(sampleRadius, -sampleRadius), size, p.invert);
            float toneDL = patternToneAt(inTex, s, center + float2(-sampleRadius, sampleRadius), size, p.invert);
            float toneDR = patternToneAt(inTex, s, center + float2(sampleRadius, sampleRadius), size, p.invert);

            float gradientX = (toneR - toneL) * 0.5;
            float gradientY = (toneD - toneU) * 0.5;
            float cardinalFeature = max(abs(toneR - toneL), abs(toneD - toneU));
            float diagonalFeature = max(abs(toneUL - toneDR), abs(toneUR - toneDL));
            float feature = max(cardinalFeature, diagonalFeature * 0.7);
            float featureWeight = smoothstep(0.025, 0.24, feature);

            // Gamma keeps highlights quiet while preserving midtone structure;
            // featureWeight brings back thin, high-contrast facial details.
            float tonalExponent = max(0.35, mix(2.35, 1.35, p.strength));
            float tonalWeight = pow(clamp(tone, 0.0, 1.0), tonalExponent);
            float density = clamp(
                tonalWeight * (0.18 + 1.08 * p.strength)
                + featureWeight * (0.08 + 0.92 * p.sampling), 0.0, 1.0);
            float coverage = clamp(density * (0.78 + 0.22 * p.strength), 0.0, 1.0);
            float rank = blueNoiseRank(candidateID);
            float presence = smoothstep(rank - 0.025, rank + 0.025, coverage);

            // A restrained attraction gives edges a more legible contour while
            // keeping the blue-noise spacing visually intact.
            float2 gradient = float2(gradientX, gradientY);
            float gradientLength = length(gradient);
            if (gradientLength > 1e-4) {
                center += gradient / gradientLength * cell * (0.05 + 0.11 * p.sampling) * featureWeight;
            }

            float signal = clamp(tonalWeight + featureWeight * 0.7, 0.0, 1.0);
            float radiusScale = mix(1.0, mix(0.38, 1.55, signal),
                                    max(0.0, p.dotResponse));
            float radius = max(0.35, p.thickness * radiusScale);
            float edge = max(0.2, p.softness * 1.4);
            float distanceToParticle = length(pos - center);
            float candidateMask = (1.0 - smoothstep(radius - edge, radius + edge,
                                                    distanceToParticle)) * presence;
            mark = max(mark, candidateMask);
        }
    }

    float4 source = inTex.sample(s, pos / size);
    outTex.write(patternComposite(mark, source, p), gid);
}

static float2 stippleRawCenter(float2 cellID, float cell, float sampling) {
    float2 h = patternHash2(cellID + float2(17.13, 7.91));
    float theta = 6.2831853 * h.x;
    // A radial multi-jitter keeps the candidate set non-axis-aligned while
    // leaving enough room for the local Poisson-distance gate below.
    float jitterRadius = cell * (0.18 + 0.36 * h.y) * (0.7 + 0.35 * sampling);
    return (cellID + 0.5) * cell
        + float2(cos(theta), sin(theta)) * jitterRadius;
}

static bool stipplePoissonAccepted(float2 cellID, float2 center,
                                   float cell, float sampling) {
    float rank = patternHash2(cellID + float2(61.7, 29.4)).x;
    float minimumDistance = cell * (0.34 + 0.08 * (1.0 - sampling));
    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            if (ox == 0 && oy == 0) continue;
            float2 neighbourID = cellID + float2(ox, oy);
            float2 neighbourCenter = stippleRawCenter(neighbourID, cell, sampling);
            float neighbourRank = patternHash2(neighbourID + float2(61.7, 29.4)).x;
            if (neighbourRank < rank && length(center - neighbourCenter) < minimumDistance) {
                return false;
            }
        }
    }
    return true;
}

// A deterministic multi-jittered particle field. Each cell contributes one
// candidate, but pixels search neighbouring cells so jittered particles are
// not clipped at cell boundaries. Candidate rank controls density while
// local tone contrast attracts particles toward features; in flat regions the
// luminance term alone controls the field.
kernel void effect_stipple(texture2d<float, access::sample> inTex [[texture(0)]],
                           texture2d<float, access::write> outTex [[texture(1)]],
                           constant PatternParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(outTex.get_width(), outTex.get_height());
    float2 pos = float2(gid) + 0.5;
    float cell = patternCellScale(p.scale);
    float2 cellID = floor(pos / cell);
    float dotMask = 0.0;

    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            float2 candidateID = cellID + float2(ox, oy);
            float2 center = stippleRawCenter(candidateID, cell, p.sampling);
            if (!stipplePoissonAccepted(candidateID, center, cell, p.sampling)) continue;

            float sampleRadius = max(1.0, cell * mix(0.16, 0.72, p.sampling));
            float tone = patternToneAt(inTex, s, center, size, p.invert);
            float toneL = patternToneAt(inTex, s, center + float2(-sampleRadius, 0), size, p.invert);
            float toneR = patternToneAt(inTex, s, center + float2(sampleRadius, 0), size, p.invert);
            float toneU = patternToneAt(inTex, s, center + float2(0, -sampleRadius), size, p.invert);
            float toneD = patternToneAt(inTex, s, center + float2(0, sampleRadius), size, p.invert);
            float feature = max(max(abs(toneR - toneL), abs(toneD - toneU)),
                                max(abs(toneR - tone), abs(toneD - tone)));

            // Move candidates toward the darker/high-ink side of a local
            // contrast feature. On flat imagery this is effectively zero and
            // the tone/density term produces the particles instead.
            float bestTone = tone;
            float2 bestDirection = float2(0);
            if (toneL > bestTone) { bestTone = toneL; bestDirection = float2(-1, 0); }
            if (toneR > bestTone) { bestTone = toneR; bestDirection = float2(1, 0); }
            if (toneU > bestTone) { bestTone = toneU; bestDirection = float2(0, -1); }
            if (toneD > bestTone) { bestTone = toneD; bestDirection = float2(0, 1); }
            float attraction = clamp(p.sampling * (0.25 + feature * 2.2), 0.0, 1.0);
            if (length(bestDirection) > 0.0) {
                center += bestDirection * cell * (0.12 + 0.25 * attraction);
            }

            float density = clamp(tone * (0.35 + 1.55 * p.strength)
                                  + feature * (0.25 + 0.9 * p.sampling), 0.0, 1.0);
            float rank = patternHash2(candidateID + float2(61.7, 29.4)).x;
            // Progressive subset: reveal the same blue-noise ordering at
            // lighter densities instead of resampling/clustering points.
            float presence = smoothstep(rank - 0.035, rank + 0.035,
                                        density * (0.72 + 0.55 * p.strength));
            float signal = clamp(tone + feature * 0.8, 0.0, 1.0);
            float radiusScale = mix(1.0, mix(0.42, 1.45, signal),
                                    max(0.0, p.dotResponse));
            float radius = max(0.45, p.thickness * radiusScale);
            float edge = max(0.25, p.softness * 1.6);
            float distanceToParticle = length(pos - center);
            float candidateMask = (1.0 - smoothstep(radius - edge, radius + edge,
                                                    distanceToParticle)) * presence;
            dotMask = max(dotMask, candidateMask);
        }
    }

    float4 source = inTex.sample(s, (pos / size));
    outTex.write(patternComposite(dotMask, source, p), gid);
}

kernel void effect_stripes(texture2d<float, access::sample> inTex [[texture(0)]],
                           texture2d<float, access::write> outTex [[texture(1)]],
                           constant PatternParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(outTex.get_width(), outTex.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float4 source = inTex.sample(s, uv);
    float2 centered = float2(gid) + 0.5 - size * 0.5;
    float angle = p.angle;
    float2 normal = float2(-sin(angle), cos(angle));
    float across = dot(centered, normal);
    float period = patternCellScale(p.scale);
    float stripeOffset = (fract(across / period + 0.5) - 0.5) * period;
    float phase = abs(stripeOffset / max(1.0, period * 0.5));
    float2 stripeCenter = float2(gid) + 0.5 - normal * stripeOffset;
    float2 along = float2(cos(angle), sin(angle));
    // Sampling amount controls how much tone/feature information contributes;
    // variationScale controls the spatial wavelength of that information.
    float sampleDistance = max(1.0, period * mix(0.1, 0.8, p.sampling)
                               * max(0.1, p.variationScale));
    float4 centerSource = inTex.sample(s, stripeCenter / size);
    float4 alongA = inTex.sample(s, (stripeCenter + along * sampleDistance) / size);
    float4 alongB = inTex.sample(s, (stripeCenter - along * sampleDistance) / size);
    float tone = patternTone(centerSource.rgb, p.invert);
    float toneA = patternTone(alongA.rgb, p.invert);
    float toneB = patternTone(alongB.rgb, p.invert);
    float feature = max(max(abs(toneA - tone), abs(toneB - tone)),
                        abs(toneA - toneB) * 0.5);
    tone = clamp(mix(tone, (toneA + toneB) * 0.5, p.sampling * 0.65)
                 + feature * p.sampling * 0.95, 0.0, 1.0);
    float baseWidth = max(0.01, p.thickness / period);
    // The reference technique maps source brightness to the width of short
    // stripe strokes. Keep response 1 equivalent to the original SketchCam
    // behavior, let 0 flatten the tonal modulation, and allow values above
    // 1 to exaggerate the width range. Bleed is an explicit upper headroom
    // control: at zero neighbouring stripes can meet but do not overlap;
    // higher values let broad dark features merge into adjacent strokes.
    float response = max(0.0, p.stripeResponse);
    float responsiveTone = clamp(0.5 + (tone - 0.5) * response, 0.0, 1.0);
    float widthSignal = responsiveTone * (0.35 + p.strength);
    float maxWidth = 1.0 + max(0.0, p.stripeBleed);
    float width = clamp(baseWidth * mix(0.35, 2.35, widthSignal), 0.01, maxWidth);
    float edge = max(0.003, p.softness * 0.18);
    float stripeMask = 1.0 - smoothstep(width - edge, width + edge, phase);
    outTex.write(patternComposite(stripeMask, source, p), gid);
}

kernel void effect_pixelate(texture2d<float, access::sample> inTex [[texture(0)]],
                            texture2d<float, access::write> outTex [[texture(1)]],
                            constant PatternParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(outTex.get_width(), outTex.get_height());
    float2 pos = float2(gid) + 0.5;
    float cell = patternCellScale(p.scale);
    float2 cellID = floor(pos / cell);
    float2 center = (cellID + 0.5) * cell;
    float4 source = inTex.sample(s, center / size);
    float tone = patternTone(source.rgb, p.invert);
    float sampleRadius = max(1.0, cell * mix(0.08, 0.55, p.sampling));
    float neighboringTone = patternTone(
        inTex.sample(s, (center + float2(sampleRadius, sampleRadius)) / size).rgb,
        p.invert
    );
    tone = mix(tone, neighboringTone, p.sampling * 0.4);
    float2 local = abs(fract(pos / cell) - 0.5) * 2.0;
    float squareDistance = max(local.x, local.y);
    float roundDistance = length(local);
    float shapeDistance = mix(squareDistance, roundDistance, max(0.0, p.softness));
    float radius = clamp(0.06 + tone * (0.68 + 0.27 * p.strength), 0.03, 0.98);
    float edge = max(0.003, p.softness * 0.16);
    float dotMask = 1.0 - smoothstep(radius - edge, radius + edge, shapeDistance);
    float blend = max(0.0, p.strength);
    outTex.write(patternComposite(dotMask * blend, source, p), gid);
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
