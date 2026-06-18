#include <metal_stdlib>
using namespace metal;

struct ControlTrackedSplatParams {
    float2 resolution;
    uint2 origin;
    float2 center;
    float radiusSq;
    float padding;
    float2 velocity;
};

struct ControlTrackedNormalizeParams {
    float smoothing;
    float decay;
    float maximumForce;
    float threshold;
};

struct ControlOpticalFlowParams {
    float2 inputSize;
    float elapsed;
    float sensitivity;
    float threshold;
    float smoothing;
    float decay;
    float maximumForce;
    uint hasFlow;
};

struct ControlCombineMotionParams {
    float maximumForce;
};

kernel void control_clear_scalar(texture2d<float, access::write> output [[texture(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    output.write(float4(0.0), gid);
}

kernel void control_clear_vector(texture2d<float, access::write> output [[texture(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    output.write(float4(0.0), gid);
}

kernel void control_resample_scalar(texture2d<float, access::sample> input [[texture(0)]],
                                    texture2d<float, access::write> output [[texture(1)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    output.write(float4(input.sample(linearSampler, uv).r, 0.0, 0.0, 1.0), gid);
}

kernel void control_resample_vector(texture2d<float, access::sample> input [[texture(0)]],
                                    texture2d<float, access::write> output [[texture(1)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    output.write(float4(input.sample(linearSampler, uv).rg, 0.0, 1.0), gid);
}

kernel void control_splat_tracked_motion(
    texture2d<float, access::read_write> vectorSum [[texture(0)]],
    texture2d<float, access::read_write> weightSum [[texture(1)]],
    constant ControlTrackedSplatParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 pixel = p.origin + gid;
    if (pixel.x >= vectorSum.get_width() || pixel.y >= vectorSum.get_height()) return;
    float2 uv = (float2(pixel) + 0.5) / p.resolution;
    float2 delta = uv - p.center;
    float weight = exp(-dot(delta, delta) / max(p.radiusSq, 1e-7));
    float2 oldVector = vectorSum.read(pixel).rg;
    float oldWeight = weightSum.read(pixel).r;
    vectorSum.write(float4(oldVector + p.velocity * weight, 0.0, 1.0), pixel);
    weightSum.write(float4(oldWeight + weight, 0.0, 0.0, 1.0), pixel);
}

kernel void control_normalize_tracked_motion(
    texture2d<float, access::read> vectorSum [[texture(0)]],
    texture2d<float, access::read> weightSum [[texture(1)]],
    texture2d<float, access::sample> previous [[texture(2)]],
    texture2d<float, access::write> vectorOut [[texture(3)]],
    texture2d<float, access::write> magnitudeOut [[texture(4)]],
    constant ControlTrackedNormalizeParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= vectorOut.get_width() || gid.y >= vectorOut.get_height()) return;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(vectorOut.get_width(), vectorOut.get_height());
    float2 prior = previous.sample(linearSampler, uv).rg;
    float weight = weightSum.read(gid).r;
    float2 velocity = prior * clamp(p.decay, 0.0, 1.0);
    if (weight > 1e-5) {
        float2 measured = vectorSum.read(gid).rg / weight;
        velocity = mix(measured, prior, clamp(p.smoothing, 0.0, 1.0));
    }
    float speed = length(velocity);
    if (!isfinite(speed) || speed < max(0.0, p.threshold)) {
        velocity = float2(0.0);
        speed = 0.0;
    } else if (speed > max(0.0, p.maximumForce)) {
        velocity *= p.maximumForce / max(speed, 1e-6);
        speed = p.maximumForce;
    }
    vectorOut.write(float4(velocity, 0.0, 1.0), gid);
    magnitudeOut.write(float4(speed, 0.0, 0.0, 1.0), gid);
}

kernel void control_filter_optical_flow(
    texture2d<float, access::sample> rawFlow [[texture(0)]],
    texture2d<float, access::sample> previous [[texture(1)]],
    texture2d<float, access::write> vectorOut [[texture(2)]],
    texture2d<float, access::write> magnitudeOut [[texture(3)]],
    constant ControlOpticalFlowParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= vectorOut.get_width() || gid.y >= vectorOut.get_height()) return;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(vectorOut.get_width(), vectorOut.get_height());
    float2 prior = previous.sample(linearSampler, uv).rg;
    float2 velocity = prior * clamp(p.decay, 0.0, 1.0);
    if (p.hasFlow != 0u) {
        float2 pixels = rawFlow.sample(linearSampler, uv).rg;
        float2 measured = pixels / max(p.inputSize, float2(1.0));
        measured *= max(0.0, p.sensitivity) / max(p.elapsed, 1.0 / 240.0);
        velocity = mix(measured, prior, clamp(p.smoothing, 0.0, 1.0));
    }
    float speed = length(velocity);
    if (!isfinite(speed) || speed < max(0.0, p.threshold)) {
        velocity = float2(0.0);
        speed = 0.0;
    } else if (speed > max(0.0, p.maximumForce)) {
        velocity *= p.maximumForce / max(speed, 1e-6);
        speed = p.maximumForce;
    }
    vectorOut.write(float4(velocity, 0.0, 1.0), gid);
    magnitudeOut.write(float4(speed, 0.0, 0.0, 1.0), gid);
}

kernel void control_combine_motion(
    texture2d<float, access::sample> trackedVector [[texture(0)]],
    texture2d<float, access::sample> trackedMagnitude [[texture(1)]],
    texture2d<float, access::sample> denseVector [[texture(2)]],
    texture2d<float, access::write> vectorOut [[texture(3)]],
    texture2d<float, access::write> magnitudeOut [[texture(4)]],
    constant ControlCombineMotionParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= vectorOut.get_width() || gid.y >= vectorOut.get_height()) return;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(vectorOut.get_width(), vectorOut.get_height());
    float2 tracked = trackedVector.sample(linearSampler, uv).rg;
    float2 dense = denseVector.sample(linearSampler, uv).rg;
    float weight = clamp(trackedMagnitude.sample(linearSampler, uv).r / max(p.maximumForce, 1e-5), 0.0, 1.0);
    float2 velocity = mix(dense, tracked, weight);
    float speed = length(velocity);
    if (!isfinite(speed)) { velocity = float2(0.0); speed = 0.0; }
    vectorOut.write(float4(velocity, 0.0, 1.0), gid);
    magnitudeOut.write(float4(speed, 0.0, 0.0, 1.0), gid);
}
