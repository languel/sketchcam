# Physical Paper and Live Motion Interaction Design

## Goal

Make paper materially affect pigment while retaining the existing paper appearance, and let human presence and movement modulate that response. The feature builds on the GPU control-field contract and must leave current Ink output unchanged when its influence is zero.

## Procedural material maps

The cached paper renderer publishes its visible texture plus three hidden scalar fields derived from the same seed, orientation, fiber, tooth, grain, and scale geometry:

- **Absorbency** controls local wetness uptake, lateral wicking, and drying tendency.
- **Drag** damps local fluid velocity and mobile-pigment transport.
- **Resist** suppresses wetness and pigment deposition in sized or waxy regions.

Visible tint, contrast, saturation, vignette, and compositing do not change these physical maps. Physical variation is stable for a given resolved paper configuration and dimensions. Threshold and softness shape Resist without creating hard aliasing at simulation resolution.

Paper exposes `Response` and `Variation` as primary controls. Response scales the combined physical effect from neutral to the configured channel strengths; Variation changes each map's contrast around its mean without changing that mean. A collapsed advanced section exposes absorbency, drag, resist amount, resist threshold, resist softness, live surface modulation, and live motion force. Ink and Acrylic each expose an independent Paper Influence multiplier.

## Live surface and force providers

Motion is a reusable control provider with three extraction modes:

- **Tracked Human** splats temporally smoothed face, hand, and body-landmark displacement into a vector field and derives magnitude from it.
- **Optical Flow** extracts a dense vector field from a selected camera or routed pixel input and publishes vector and magnitude outputs.
- **Combined** uses dense flow where confidence is sufficient and reinforces it with reliable tracked-human vectors.

Controls include input, mode, sensitivity, noise threshold, temporal smoothing, decay, spatial scale, and maximum force. Dense flow runs at reduced simulation resolution, rejects low-confidence motion, and reuses its intermediate textures. Disabling flow releases its active processing resources.

Consumers may use motion magnitude to modulate absorbency, drag, or resist, and may separately inject motion vectors into their velocity field. Surface modulation and vector force always have independent strengths. If a live source disappears, its fields decay smoothly to zero; simulation state is retained.

## Simulation behavior

For Ink, paper response is applied in bounded stages:

1. Resist scales new wetness and pigment deposition.
2. Absorbency scales wetness spreading and local wetness loss into paper.
3. Drag scales velocity and mobile-pigment advection.
4. Live scalar modulation adjusts the configured paper response.
5. Live vectors add a clamped force before velocity advection.

All modifiers are normalized and clamped so extreme combinations cannot create negative wetness, unbounded velocity, or NaNs. Default Paper Influence, live surface modulation, and motion force are zero for existing projects. Enabling paper response must not change the visible cached paper texture.

## Validation

Use deterministic test patterns to verify that absorbent areas wick and dry faster, drag areas slow transport, and resist areas reject deposition with controllable edge softness. Synthetic frame translations must produce correctly directed dense flow, while moving landmarks must produce smooth localized vectors. Combined mode must fall back to either available provider. Regression captures compare current Ink with all new influences disabled. Performance validation records separate timings for paper-field generation, tracked motion, dense flow, and Ink consumption and confirms no CPU readback in the frame loop.
