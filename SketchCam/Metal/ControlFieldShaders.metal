#include <metal_stdlib>
using namespace metal;

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
