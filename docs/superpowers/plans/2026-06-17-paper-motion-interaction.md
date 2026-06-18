# Physical Paper and Live Motion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish cached physical paper fields and reusable tracked/dense motion fields, then let Ink consume them without changing its disabled baseline.

**Architecture:** Extend the existing cached Metal paper renderer to produce three hidden scalar textures. Add tracked-landmark and Vision optical-flow providers that publish magnitude/vector textures into `GPUControlFieldStore`; bind those fields into bounded Ink shader stages.

**Tech Stack:** Swift 5, SwiftUI, Metal compute, Vision `VNGenerateOpticalFlowRequest`, Core Video, XcodeGen/XCTest.

---

### Task 1: Add paper-response and motion settings

**Files:**
- Modify: `SketchCamCore/Sources/LayerGraph.swift`
- Modify: `SketchCamCore/Sources/ControlFieldGraph.swift`
- Modify: `SketchCamCore/Sources/ProcessingSettings.swift`
- Modify: `Tests/SketchCamCoreTests/LayerGraphTests.swift`
- Modify: `Tests/SketchCamCoreTests/ControlFieldGraphTests.swift`

- [ ] **Step 1: Write failing legacy/default tests**

Assert that old Paper JSON resolves Response to one while Ink Paper Influence resolves to zero, new paper settings round-trip, and Motion defaults to disabled Combined mode with zero surface/force strengths.

- [ ] **Step 2: Add model types and defaults**

Extend `PaperConfig` with optional `response`, `variation`, `absorbency`, `drag`, `resist`, `resistThreshold`, and `resistSoftness`. Resolve missing values to `1, 1, 1, 1, 1, 0.5, 0.1` respectively. Compatibility comes from each medium's zero Paper Influence, so enabling influence immediately reveals the default paper response instead of requiring two controls to change.

Add:

```swift
public enum MotionExtractionMode: String, Codable, Sendable, CaseIterable { case trackedHuman, opticalFlow, combined }
public enum MotionInputSource: String, Codable, Sendable, CaseIterable { case camera, movie, inkTexture }
public struct MotionControlConfig: Codable, Sendable, Equatable {
    public var enabled = false
    public var mode: MotionExtractionMode = .combined
    public var input: MotionInputSource = .camera
    public var sensitivity: Float = 1
    public var threshold: Float = 0.03
    public var smoothing: Float = 0.7
    public var decay: Float = 0.85
    public var spatialScale: Float = 1
    public var maximumForce: Float = 1
}
```

Add optional Ink settings `inkPaperInfluence`, `inkLiveSurfaceInfluence`, and `inkMotionForce`, all resolving to zero. Add advanced live target weights `inkLiveAbsorbency`, `inkLiveDrag`, and `inkLiveResist`, resolving to `0`, `0.5`, and `1`; the Live Surface macro multiplies these weights.

Add optional `motionConfig: MotionControlConfig?` and `paperNodeID: UUID?` to `ControlFieldProvider`. A Paper provider with a node ID reads that Paper node's configuration; nil reads Ink's internal paper. Motion providers use `motionConfig`; missing configuration resolves to the defaults above. When Motion is enabled in the UI, create Tracked, Optical Flow, and Combined providers once and route the selected mode's outputs without recreating their IDs.

- [ ] **Step 3: Run Core tests and commit**

Use `/tmp/sketchcam-paper-motion` as DerivedData, run direct `xctest`, and commit with `git commit -m "Add paper response and motion settings"`.

### Task 2: Generate cached paper material fields

**Files:**
- Modify: `SketchCam/Metal/MetalPaperRenderer.swift`
- Modify: `SketchCam/Metal/InkWashShaders.metal`

- [ ] **Step 1: Add a failing cache behavior self-check**

In DEBUG, request the same configuration twice and assert one generation, identical field texture identities, and no new generation when only tint/contrast/saturation changes. Changing geometry, seed, Response, or dimensions must generate a new material set.

- [ ] **Step 2: Split visible and physical cache keys**

Return this handle from a new API while keeping `texture(config:size:commandBuffer:)` as a wrapper for `visible`:

```swift
struct PaperTextureSet {
    let visible: MTLTexture
    let absorbency: MTLTexture
    let drag: MTLTexture
    let resist: MTLTexture
    let materialRevision: UInt64
}
func textures(config: PaperConfig, size: CGSize, commandBuffer: MTLCommandBuffer) -> PaperTextureSet?
```

Cache material fields by geometry/response settings and visible paper by the full resolved configuration. Material textures use `.r16Float` and remain private GPU textures.

- [ ] **Step 3: Add the material shader**

Add `ink_generate_paper_material` using the same fiber/tooth/grain noise coordinates as `ink_generate_paper`. Compute each channel as a mean-preserving contrast transform, then shape Resist with smoothstep:

```metal
float vary(float n, float amount) { return clamp(0.5 + (n - 0.5) * amount, 0.0, 1.0); }
float resist = smoothstep(threshold - softness, threshold + softness, vary(materialNoise, variation));
absorbency.write(response * absorbencyAmount * vary(1.0 - materialNoise, variation), gid);
drag.write(response * dragAmount * vary(materialNoise, variation), gid);
resistOut.write(response * resistAmount * resist, gid);
```

- [ ] **Step 4: Publish paper outputs and commit**

Add `PaperControlFieldProvider` to publish the three textures/revision into `GPUControlFieldStore`. Build the app and commit with `git commit -m "Generate cached paper response fields"`.

### Task 3: Add tracked-human motion fields

**Files:**
- Create: `SketchCam/Metal/TrackedMotionFieldProvider.swift`
- Modify: `SketchCam/Metal/ControlFieldShaders.metal`

- [ ] **Step 1: Add deterministic displacement fixtures**

Under DEBUG, feed two labeled detections translated by `(0.1, -0.05)`. Assert the provider publishes `.motionVector` and `.motionMagnitude`, ignores unlabeled/low-confidence points, and decays toward zero after detections stop.

- [ ] **Step 2: Implement labeled displacement matching**

Match points by `region.rawValue + label`, compute displacement divided by elapsed time, clamp by Maximum Force, and encode Gaussian splats into `.rg16Float` vector and `.r16Float` weight textures. Normalize weighted vectors in `control_normalize_tracked_motion`, derive magnitude, then apply temporal smoothing/decay in ping-pong textures.

- [ ] **Step 3: Build and commit**

Run the unsigned app build and commit with `git commit -m "Add tracked human motion fields"`.

### Task 4: Add dense optical-flow fields

**Files:**
- Create: `SketchCam/Metal/OpticalFlowFieldProvider.swift`
- Modify: `SketchCam/Metal/ControlFieldShaders.metal`
- Modify: `SketchCam/App/SketchCamViewModel.swift`

- [ ] **Step 1: Create a synthetic translation check**

Generate two 256-pixel test buffers with a high-contrast square translated eight pixels right. Assert median nonzero X flow is positive, Y is near zero, and magnitude below the configured threshold becomes zero.

- [ ] **Step 2: Implement asynchronous Vision extraction**

Downsample consecutive selected input frames to identical dimensions, allow only one request in flight, and drop work rather than queueing. Configure each request as:

```swift
let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: previous, options: [:])
request.computationAccuracy = quality == .high ? .medium : .low
request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
request.keepNetworkOutput = false
try VNImageRequestHandler(cvPixelBuffer: current).perform([request])
```

Wrap the resulting `VNPixelBufferObservation.pixelBuffer` with `CVMetalTextureCache` as `.rg16Float`; never read its pixels on CPU.

- [ ] **Step 3: Normalize, threshold, smooth, and combine**

Encode `control_filter_optical_flow` to convert pixel displacement to normalized canvas velocity, remove values below threshold, clamp Maximum Force, compute magnitude, and apply smoothing/decay. Combined mode blends dense flow with tracked vectors by tracked weight, favoring tracked motion where present.

- [ ] **Step 4: Wire selected input and commit**

Pass camera, movie, or routed Ink texture buffers from the frame context. If a selected input disappears, decay published fields to zero. Record `.motion` timing and commit with `git commit -m "Add optical flow control source"`.

### Task 5: Apply paper and motion to Ink

**Files:**
- Modify: `SketchCam/Landmarks/MetalInkEngine.swift`
- Modify: `SketchCam/Landmarks/InkLayerCompositor.swift`
- Modify: `SketchCam/Metal/InkWashShaders.metal`

- [ ] **Step 1: Capture a disabled baseline**

Render a fixed-seed retained stroke with all three influence values zero and save its output hash. This hash must remain identical after shader bindings are added.

- [ ] **Step 2: Bind zero-safe fields into bounded stages**

Pass scalar fields to splat/deposition, wetness, velocity, and ink-advection kernels; pass motion vector to a new `ink_add_control_force` kernel before velocity advection. Apply exactly:

```metal
float resistScale = 1.0 - clamp(resist * paperInfluence, 0.0, 1.0);
float absorb = clamp(absorbency * paperInfluence + liveSurface * liveSurfaceInfluence * liveAbsorbency, 0.0, 1.0);
float liveDragValue = liveSurface * liveSurfaceInfluence * liveDrag;
float liveResistValue = liveSurface * liveSurfaceInfluence * liveResist;
float dragScale = exp(-max(0.0, drag * paperInfluence) * dt);
velocity *= dragScale;
velocity += clamp_length(motionVector * motionForce, maximumControlForce) * dt;
```

Add `liveResistValue` to Resist before deposition and `liveDragValue` to Drag before damping. Resist scales new wetness/pigment deposition; absorbency scales spread and wetness decay; drag damps velocity and mobile-pigment transport. Clamp every field sample and finite-check velocity before writing.

- [ ] **Step 3: Verify baseline and characteristic scenes**

Confirm the zero-influence hash is unchanged. Then verify deterministic absorbent, drag, resist, scalar-motion, and directional-motion fixtures produce distinct expected behavior.

- [ ] **Step 4: Commit Ink integration**

Commit with `git commit -m "Drive Ink with paper and motion fields"`.

### Task 6: Add Paper Response and Motion UI

**Files:**
- Modify: `SketchCam/App/ContentView.swift`

- [ ] **Step 1: Add compact paper controls**

Place Response and Variation near the top of `PaperControls`. Add a nested collapsed `DisclosureGroup("Physical response")` with Absorbency, Drag, Resist, Threshold, and Softness. Use ranges `0...1`, except Variation `0...2`.

- [ ] **Step 2: Add reusable Motion source editor**

Expose Enable, extraction mode, input stream, Quality, Sensitivity, Threshold, Smoothing, Decay, Spatial Scale, and Maximum Force. In Ink, expose Paper Influence, Live Surface, and Motion Force; all default to zero for migrated projects. Put Live → Absorbency, Drag, and Resist weights in the advanced Paper Response disclosure. Control-input menus list provider plus named output and omit incompatible scalar/vector outputs.

- [ ] **Step 3: Visually verify and commit**

Confirm controls remain collapsible and do not crowd ordinary paper appearance controls. Commit with `git commit -m "Expose physical paper and motion controls"`.

### Task 7: Full verification

**Files:**
- Test: `Tests/SketchCamCoreTests/ControlFieldGraphTests.swift`

- [ ] Run Core tests and unsigned Debug app build.
- [ ] Verify optical flow is lazy, one request at a time, and contributes no work when disabled.
- [ ] Verify provider disappearance decays to zero without clearing Ink.
- [ ] Verify Paper Response zero reproduces current Ink and visible paper exactly.
- [ ] Run `git diff --check`; commit only verification fixes.
