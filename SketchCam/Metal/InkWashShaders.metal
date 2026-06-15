#include <metal_stdlib>
using namespace metal;

struct InkSplatParams {
    float2 targetSize;
    uint2 origin;
    float aspect;
    float pad0;
    float2 point;
    float radiusSq;
    uint blendMode; // 0 = add, 1 = max
    float4 color;
};

struct InkCopyParams {
    float value;
};

struct InkAdvectVelocityParams {
    float2 texel;
    float dt;
    float dissipation;
};

struct InkVorticityParams {
    float2 texel;
    float curlAmount;
    float dt;
};

struct InkAdvectWetParams {
    float2 velTexel;
    float2 wetTexel;
    float dt;
    float decay;
    float spread;
    float pad0;
};

struct InkAdvectInkParams {
    float2 velTexel;
    float2 inkTexel;
    float dt;
    float bleed;
    float aspect;
    float pad0;
    float3 chroma;
    float pad1;
    float3 brush; // x, y, radius
    float pad2;
};

struct InkExchangeParams {
    float settle;
    float dt;
    float aspect;
    float mode; // 0 fixed output, 1 mobile output
    float4 brush; // x, y, radius, lift (destructive re-mobilization amount)
};

struct InkDisplayParams {
    float2 texel;
    float2 res;
    float inkStrength;
    float edge;
    float grain;
    float whiteTint;
    float opacity;
    float paperOn;
};

static float2 uv_for(uint2 gid, uint w, uint h) {
    return (float2(gid) + 0.5) / float2(w, h);
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p *= 2.07;
        a *= 0.5;
    }
    return v;
}

kernel void ink_clear(texture2d<float, access::write> outTex [[texture(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    outTex.write(float4(0.0), gid);
}

kernel void ink_copy(texture2d<float, access::sample> inTex [[texture(0)]],
                     texture2d<float, access::write> outTex [[texture(1)]],
                     constant InkCopyParams &p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, outTex.get_width(), outTex.get_height());
    outTex.write(inTex.sample(s, uv) * p.value, gid);
}

kernel void ink_splat(texture2d<float, access::read_write> target [[texture(0)]],
                      constant InkSplatParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint2 px = p.origin + gid;
    if (px.x >= target.get_width() || px.y >= target.get_height()) return;
    float2 uv = (float2(px) + 0.5) / p.targetSize;
    float2 d = uv - p.point;
    d.x *= p.aspect;
    float4 mark = p.color * exp(-dot(d, d) / max(p.radiusSq, 1e-7));
    float4 old = target.read(px);
    target.write(p.blendMode == 1u ? max(old, mark) : old + mark, px);
}

kernel void ink_advect_velocity(texture2d<float, access::sample> velocityIn [[texture(0)]],
                                texture2d<float, access::sample> wetIn [[texture(1)]],
                                texture2d<float, access::write> velocityOut [[texture(2)]],
                                constant InkAdvectVelocityParams &p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= velocityOut.get_width() || gid.y >= velocityOut.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, velocityOut.get_width(), velocityOut.get_height());
    float2 coord = uv - p.dt * velocityIn.sample(s, uv).xy * p.texel;
    float2 vel = velocityIn.sample(s, coord).xy * p.dissipation;
    float w = wetIn.sample(s, uv).x;
    float mask = smoothstep(0.005, 0.2, w);
    velocityOut.write(float4(vel * mask, 0.0, 1.0), gid);
}

kernel void ink_curl(texture2d<float, access::sample> velocity [[texture(0)]],
                     texture2d<float, access::write> curlOut [[texture(1)]],
                     constant InkAdvectVelocityParams &p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= curlOut.get_width() || gid.y >= curlOut.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, curlOut.get_width(), curlOut.get_height());
    float L = velocity.sample(s, uv - float2(p.texel.x, 0.0)).y;
    float R = velocity.sample(s, uv + float2(p.texel.x, 0.0)).y;
    float B = velocity.sample(s, uv - float2(0.0, p.texel.y)).x;
    float T = velocity.sample(s, uv + float2(0.0, p.texel.y)).x;
    curlOut.write(float4(0.5 * ((R - L) - (T - B)), 0.0, 0.0, 1.0), gid);
}

kernel void ink_vorticity(texture2d<float, access::sample> velocityIn [[texture(0)]],
                          texture2d<float, access::sample> curlIn [[texture(1)]],
                          texture2d<float, access::write> velocityOut [[texture(2)]],
                          constant InkVorticityParams &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= velocityOut.get_width() || gid.y >= velocityOut.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, velocityOut.get_width(), velocityOut.get_height());
    float L = curlIn.sample(s, uv - float2(p.texel.x, 0.0)).x;
    float R = curlIn.sample(s, uv + float2(p.texel.x, 0.0)).x;
    float B = curlIn.sample(s, uv - float2(0.0, p.texel.y)).x;
    float T = curlIn.sample(s, uv + float2(0.0, p.texel.y)).x;
    float C = curlIn.sample(s, uv).x;
    float2 force = 0.5 * float2(abs(T) - abs(B), abs(R) - abs(L));
    force /= length(force) + 1e-4;
    force *= p.curlAmount * C * float2(1.0, -1.0);
    float2 vel = velocityIn.sample(s, uv).xy + force * p.dt;
    velocityOut.write(float4(clamp(vel, -1000.0, 1000.0), 0.0, 1.0), gid);
}

kernel void ink_divergence(texture2d<float, access::sample> velocity [[texture(0)]],
                           texture2d<float, access::write> divergenceOut [[texture(1)]],
                           constant InkAdvectVelocityParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= divergenceOut.get_width() || gid.y >= divergenceOut.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, divergenceOut.get_width(), divergenceOut.get_height());
    float L = velocity.sample(s, uv - float2(p.texel.x, 0.0)).x;
    float R = velocity.sample(s, uv + float2(p.texel.x, 0.0)).x;
    float B = velocity.sample(s, uv - float2(0.0, p.texel.y)).y;
    float T = velocity.sample(s, uv + float2(0.0, p.texel.y)).y;
    divergenceOut.write(float4(0.5 * (R - L + T - B), 0.0, 0.0, 1.0), gid);
}

kernel void ink_pressure(texture2d<float, access::sample> pressureIn [[texture(0)]],
                         texture2d<float, access::sample> divergence [[texture(1)]],
                         texture2d<float, access::write> pressureOut [[texture(2)]],
                         constant InkAdvectVelocityParams &p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= pressureOut.get_width() || gid.y >= pressureOut.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, pressureOut.get_width(), pressureOut.get_height());
    float L = pressureIn.sample(s, uv - float2(p.texel.x, 0.0)).x;
    float R = pressureIn.sample(s, uv + float2(p.texel.x, 0.0)).x;
    float B = pressureIn.sample(s, uv - float2(0.0, p.texel.y)).x;
    float T = pressureIn.sample(s, uv + float2(0.0, p.texel.y)).x;
    float div = divergence.sample(s, uv).x;
    pressureOut.write(float4((L + R + B + T - div) * 0.25, 0.0, 0.0, 1.0), gid);
}

kernel void ink_gradient_subtract(texture2d<float, access::sample> pressure [[texture(0)]],
                                  texture2d<float, access::sample> velocityIn [[texture(1)]],
                                  texture2d<float, access::write> velocityOut [[texture(2)]],
                                  constant InkAdvectVelocityParams &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= velocityOut.get_width() || gid.y >= velocityOut.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, velocityOut.get_width(), velocityOut.get_height());
    float L = pressure.sample(s, uv - float2(p.texel.x, 0.0)).x;
    float R = pressure.sample(s, uv + float2(p.texel.x, 0.0)).x;
    float B = pressure.sample(s, uv - float2(0.0, p.texel.y)).x;
    float T = pressure.sample(s, uv + float2(0.0, p.texel.y)).x;
    float2 vel = velocityIn.sample(s, uv).xy - 0.5 * float2(R - L, T - B);
    velocityOut.write(float4(vel, 0.0, 1.0), gid);
}

kernel void ink_advect_wet(texture2d<float, access::sample> velocity [[texture(0)]],
                           texture2d<float, access::sample> wetIn [[texture(1)]],
                           texture2d<float, access::write> wetOut [[texture(2)]],
                           constant InkAdvectWetParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= wetOut.get_width() || gid.y >= wetOut.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, wetOut.get_width(), wetOut.get_height());
    float2 coord = uv - p.dt * velocity.sample(s, uv).xy * p.velTexel * 0.6;
    float w = wetIn.sample(s, coord).x;
    float2 b = p.wetTexel * 1.6;
    float n = (wetIn.sample(s, coord + float2(b.x, 0.0)).x +
               wetIn.sample(s, coord - float2(b.x, 0.0)).x +
               wetIn.sample(s, coord + float2(0.0, b.y)).x +
               wetIn.sample(s, coord - float2(0.0, b.y)).x) * 0.25;
    w = mix(w, n, p.spread);
    wetOut.write(float4(w * p.decay, 0.0, 0.0, 1.0), gid);
}

kernel void ink_advect_ink(texture2d<float, access::sample> velocity [[texture(0)]],
                           texture2d<float, access::sample> inkIn [[texture(1)]],
                           texture2d<float, access::sample> wet [[texture(2)]],
                           texture2d<float, access::write> inkOut [[texture(3)]],
                           constant InkAdvectInkParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inkOut.get_width() || gid.y >= inkOut.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, inkOut.get_width(), inkOut.get_height());
    float w = wet.sample(s, uv).x;
    float mob = smoothstep(0.02, 0.45, w);
    float4 cur = inkIn.sample(s, uv);
    if (mob < 0.002) {
        inkOut.write(cur, gid);
        return;
    }
    float2 vel = velocity.sample(s, uv).xy;
    float2 coord = uv - p.dt * vel * p.velTexel * mob;
    float4 adv = inkIn.sample(s, coord);
    float brush = 0.0;
    if (p.brush.z > 0.0) {
        float2 d = uv - p.brush.xy;
        d.x *= p.aspect;
        brush = exp(-dot(d, d) / (p.brush.z * p.brush.z));
    }
    float2 b = p.inkTexel * 1.6;
    float4 n = (inkIn.sample(s, coord + float2(b.x, 0.0)) +
                inkIn.sample(s, coord - float2(b.x, 0.0)) +
                inkIn.sample(s, coord + float2(0.0, b.y)) +
                inkIn.sample(s, coord - float2(0.0, b.y))) * 0.25;
    float4 bleedAmt = clamp(p.bleed * (0.25 + 1.3 * brush) * mob * float4(p.chroma, 1.05), 0.0, 0.92);
    float4 mixed = mix(adv, n, bleedAmt);
    inkOut.write(mix(cur, mixed, mob), gid);
}

kernel void ink_exchange(texture2d<float, access::sample> fixedIn [[texture(0)]],
                         texture2d<float, access::sample> inkIn [[texture(1)]],
                         texture2d<float, access::sample> wet [[texture(2)]],
                         texture2d<float, access::write> outTex [[texture(3)]],
                         constant InkExchangeParams &p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, outTex.get_width(), outTex.get_height());
    float4 F = fixedIn.sample(s, uv);
    float4 M = inkIn.sample(s, uv);
    float brush = 0.0;
    if (p.brush.z > 0.0) {
        float2 d = uv - p.brush.xy;
        d.x *= p.aspect;
        brush = exp(-dot(d, d) / (p.brush.z * p.brush.z));
    }
    // A destructive (immediate) wash re-mobilizes dried (fixed) pigment under
    // the brush back into the mobile layer, where the velocity field
    // pushes/smears it. The lift amount rides in brush.w (0 = additive wash).
    float lift = brush * p.brush.w;
    if (p.mode < 0.5) {
        float3 fd = F.rgb * (1.0 - lift) + M.rgb * p.settle;
        float fw = F.a * (1.0 - lift) + M.a * p.settle;
        if (p.settle > 0.0) {
            float c = (1.0 - exp(-2.2 * fw)) * p.settle;
            float3 T = exp(-fd);
            fd = -log(clamp(T * (1.0 - c) + c, float3(1e-4), float3(1.0)));
            fw *= 1.0 - p.settle;
        }
        outTex.write(float4(fd, fw), gid);
    } else {
        outTex.write(M * (1.0 - p.settle) + F * lift, gid);
    }
}

kernel void ink_display(texture2d<float, access::sample> ink [[texture(0)]],
                        texture2d<float, access::sample> fixedTex [[texture(1)]],
                        texture2d<float, access::sample> wet [[texture(2)]],
                        texture2d<float, access::write> outTex [[texture(3)]],
                        constant InkDisplayParams &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = uv_for(gid, outTex.get_width(), outTex.get_height());
    auto pig = [&](float2 q) { return ink.sample(s, q) + fixedTex.sample(s, q); };
    float4 pw = pig(uv);
    float3 dens = pw.rgb;
    float c = dot(dens, float3(1.0));
    float l = dot(pig(uv - float2(p.texel.x, 0.0)).rgb, float3(1.0));
    float r = dot(pig(uv + float2(p.texel.x, 0.0)).rgb, float3(1.0));
    float b = dot(pig(uv - float2(0.0, p.texel.y)).rgb, float3(1.0));
    float t = dot(pig(uv + float2(0.0, p.texel.y)).rgb, float3(1.0));
    float edge = length(float2(r - l, t - b));
    float2 px = uv * p.res;
    float fiber = fbm(px * 0.055);
    float tooth = vnoise(px * 0.42);
    float grain = fbm(px * 0.12 + 31.7);
    float3 paper = float3(0.962, 0.954, 0.930);
    paper -= (fiber - 0.5) * 0.05;
    paper -= (tooth - 0.5) * 0.022;
    float3 absb = dens * p.inkStrength;
    absb *= 1.0 + (grain - 0.5) * p.grain * clamp(c * 2.0, 0.0, 1.0);
    absb *= 1.0 + edge * p.edge;
    float3 col = paper * exp(-absb);
    float cov = 1.0 - exp(-pw.a * 2.2);
    cov = clamp(cov * (1.0 - (grain - 0.5) * 0.35), 0.0, 1.0);
    float3 wcol = mix(float3(0.985, 0.982, 0.972), float3(0.945, 0.955, 1.0), p.whiteTint);
    col = mix(col, wcol, cov);
    float wraw = wet.sample(s, uv).x;
    float ws = smoothstep(0.02, 0.6, wraw);
    col *= float3(1.0) - ws * float3(0.16, 0.15, 0.11);
    float2 q = uv - 0.5;
    col *= 1.0 - dot(q, q) * 0.16;

    float densityAlpha = clamp(1.0 - exp(-(c + pw.a) * 1.4), 0.0, 1.0);
    float alpha = p.opacity * mix(densityAlpha, 1.0, p.paperOn);
    outTex.write(float4(col * alpha, alpha), gid);
}
