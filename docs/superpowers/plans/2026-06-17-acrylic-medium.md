# Acrylic Medium Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add independently layered wet acrylic paint that ranges from glaze to heavy body, dries irreversibly, mixes by selectable RGB or pigment rules, and covers dried black Ink.

**Architecture:** Store Acrylic configuration and retained strokes on each Acrylic graph node and own one `MetalAcrylicEngine` per node ID. The engine maintains separate wet and dry thickness/color state, consumes shared control fields, and returns a transparent premultiplied layer for the existing compositor.

**Tech Stack:** Swift 5, SwiftUI, Metal compute, Core Image/Core Video, XcodeGen/XCTest.

---

### Task 1: Add Acrylic models and graph nodes

**Files:**
- Create: `SketchCamCore/Sources/AcrylicConfig.swift`
- Modify: `SketchCamCore/Sources/LayerGraph.swift`
- Modify: `Tests/SketchCamCoreTests/LayerGraphTests.swift`

- [ ] **Step 1: Write failing model tests**

Test default fluid-acrylic values, Body macro presets at 0/0.5/1, stroke round-trip, `.acrylic` node validation, and legacy graph decoding without Acrylic.

- [ ] **Step 2: Add stable public models**

```swift
public enum AcrylicMixModel: String, Codable, Sendable, CaseIterable { case rgb, pigment }
public struct AcrylicStroke: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var points: [CGPoint]
    public var color: RGBAColor
    public var width: Float
    public var loading: Float
    public var body: Float
    public var mixModel: AcrylicMixModel
}
public struct AcrylicConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var strokes: [AcrylicStroke]
    public var color: RGBAColor
    public var body: Float
    public var pigmentOpacity: Float
    public var viscosity: Float
    public var leveling: Float
    public var brushRetention: Float
    public var paintLoading: Float
    public var flow: Float
    public var dryRate: Float
    public var mixModel: AcrylicMixModel
    public var paperInfluence: Float
    public var liveSurfaceInfluence: Float
    public var liveAbsorbency: Float
    public var liveDrag: Float
    public var liveResist: Float
    public var motionForce: Float
    public var rebuildRevision: Int
    public var clearRevision: Int
    public var instantDryRevision: Int
}
```

Add `.acrylic(AcrylicConfig)` to `NodeKind`, with `strokes:path` and optional `texture:pixel` visible ports matching Ink's routing semantics. Its control-field consumer ID is `.acrylic(node.id)`.

- [ ] **Step 3: Implement Body macro mapping**

Add `mutating func applyBody(_ value: Float)` that clamps value and writes coordinated values. Use three linear interpolation anchors:

```swift
// glaze, fluid, heavy
pigmentOpacity = curve(value, 0.25, 0.85, 1.0)
viscosity = curve(value, 0.10, 0.45, 0.95)
leveling = curve(value, 0.90, 0.50, 0.08)
brushRetention = curve(value, 0.05, 0.35, 0.95)
paintLoading = curve(value, 0.30, 0.65, 1.0)
flow = curve(value, 0.90, 0.55, 0.15)
```

Moving Body reapplies these values; later individual edits do not move Body.

- [ ] **Step 4: Run tests and commit**

Run Core tests from `/tmp/sketchcam-acrylic`, then commit with `git commit -m "Add acrylic layer models"`.

### Task 2: Add Acrylic input and engine lifecycle

**Files:**
- Create: `SketchCam/Landmarks/AcrylicLiveStroke.swift`
- Create: `SketchCam/Landmarks/AcrylicLayerCompositor.swift`
- Modify: `SketchCam/App/SketchCamViewModel.swift`
- Modify: `SketchCam/App/ContentView.swift`

- [ ] **Step 1: Add node-targeted live stroke state**

Mirror the reliable Ink live-stroke handoff, but include `nodeID`, Acrylic color/loading/body/mix model, and dense points. Keep active state in the view model so switching panels ends the stroke cleanly.

- [ ] **Step 2: Add compositor registry**

`AcrylicLayerCompositor` owns `[UUID: MetalAcrylicEngine]`, creates engines lazily for visible Acrylic nodes, removes engines for deleted nodes, and returns `[UUID: CIImage]`. It receives `ResolvedControlFields` and routed substrate images but never mutates Ink.

- [ ] **Step 3: Route pointer input to the selected Acrylic node**

Add Acrylic as a drawing tab/source. When an Acrylic node is selected, preview drags create/update/end `AcrylicLiveStrokeSample`; otherwise existing Ink and editor gestures are unchanged.

- [ ] **Step 4: Build and commit lifecycle wiring**

The engine is still a transparent stub in this task. Build and commit with `git commit -m "Add acrylic layer lifecycle"`.

### Task 3: Implement wet paint state and deposition

**Files:**
- Create: `SketchCam/Landmarks/MetalAcrylicEngine.swift`
- Create: `SketchCam/Metal/AcrylicShaders.metal`
- Modify: `project.yml`

- [ ] **Step 1: Add DEBUG state invariants**

After every encoded step in debug builds, schedule a tiny reduction that flags negative/nonfinite thickness, wetness outside `0...1`, or nonfinite velocity. Assert the flag remains zero for empty, single-stroke, and extreme-control fixtures.

- [ ] **Step 2: Allocate independent state**

Use simulation-resolution `.rg16Float` velocity and dye-resolution textures: wet color mass `.rgba16Float`, wet thickness `.r16Float`, binder wetness `.r16Float`, dry premultiplied coverage `.rgba16Float`, and dry accumulated thickness `.r16Float`. Use ping-pong textures only for advected wet state. Dry coverage is composited, not mass-mixed, so later coats can cover earlier dark paint.

- [ ] **Step 3: Deposit live and retained strokes**

Encode capsules between dense points. Deposit thickness by Loading and pressure, color mass as `linearRGB * depositedThickness`, binder wetness by Flow, and velocity from stroke movement. Resist scales deposition before any write. Stamp each retained stroke's stored mix model; changing the current UI model never mutates older stroke data.

- [ ] **Step 4: Build and commit**

Register files with XcodeGen, build, and commit with `git commit -m "Add acrylic wet paint state"`.

### Task 4: Add transport, body, paper response, and drying

**Files:**
- Modify: `SketchCam/Landmarks/MetalAcrylicEngine.swift`
- Modify: `SketchCam/Metal/AcrylicShaders.metal`

- [ ] **Step 1: Implement bounded transport**

Advect velocity, wet thickness, color mass, and binder wetness. Derive coefficients from explicit controls, not directly from Body after `applyBody`:

```metal
velocity *= exp(-viscosity * viscosityScale * dt);
thickness = mix(advectedThickness, localAverageThickness, leveling * binderWetness * dt);
float retention = 1.0 - brushRetention * depositedBrushMask;
thickness = mix(thickness, previousThickness, retention);
```

Apply paper Drag and motion force using the same bounded formulas as Ink. Paper Absorbency increases binder loss and edge setting; Resist only affects new deposition.

- [ ] **Step 2: Implement gradual and instant drying**

Per step, transfer `dryFraction = clamp(dryRate * dt * (1 - binderWetness), 0, 1)` from wet thickness/color mass. Convert the transferred portion to premultiplied coverage and alpha-composite it over existing dry coverage; add transferred thickness to dry thickness. Subtract the same thickness and color mass from wet state. Instant Dry performs the same operation with fraction 1, then clears wet velocity/binder state. This preserves ordered overpainting instead of averaging a pale coat with dried black beneath it.

- [ ] **Step 3: Verify dry immobility and commit**

Confirm motion fields move only wet paint; dry pixels retain exact thickness/color hashes. Commit with `git commit -m "Add acrylic body and drying physics"`.

### Task 5: Implement selectable color mixing and opaque rendering

**Files:**
- Modify: `SketchCam/Metal/AcrylicShaders.metal`
- Modify: `SketchCam/Landmarks/MetalAcrylicEngine.swift`

- [ ] **Step 1: Implement RGB and pigment contact rules**

RGB mixes linear color mass by thickness. Pigment mode converts incoming and contacted wet RGB to approximate Kubelka-Munk absorption/scattering ratios, mass-averages them, then converts back for stored color:

```metal
float3 rgbMix(float3 c0, float m0, float3 c1, float m1) {
    return (c0 * m0 + c1 * m1) / max(m0 + m1, 1e-5);
}
float3 toKS(float3 rgb) {
    float3 r = clamp(rgb, float3(1e-3), float3(0.999));
    return ((1.0 - r) * (1.0 - r)) / (2.0 * r);
}
float3 fromKS(float3 ks) { return 1.0 + ks - sqrt(max(ks * ks + 2.0 * ks, 0.0)); }
float3 pigmentMix(float3 c0, float m0, float3 c1, float m1) {
    return fromKS(rgbMix(toKS(c0), m0, toKS(c1), m1));
}
```

The selected rule runs only in deposition/contact kernels. Untouched pixels are never reprocessed when the UI selection changes.

- [ ] **Step 2: Render coverage and relief**

Compute wet premultiplied alpha as `1 - exp(-pigmentOpacity * wetThickness * coverageScale)`. Composite wet coverage over stored dry coverage within the Acrylic layer, add restrained wet sheen from binder wetness, and derive a screen-space normal from total thickness gradients for high-Body relief. Return transparent pixels where total thickness is zero.

- [ ] **Step 3: Verify pale-over-black acceptance scene**

Place a pale Acrylic node above fixed black Ink. The center of a sufficiently loaded stroke must approach the configured pale color rather than gray; lowering opacity/loading must reveal black progressively.

- [ ] **Step 4: Commit rendering**

Commit with `git commit -m "Render opaque mixed acrylic paint"`.

### Task 6: Composite multiple Acrylic nodes

**Files:**
- Modify: `SketchCam/App/SketchCamViewModel.swift`
- Modify: `SketchCam/Metal/MetalLayerCompositor.swift`
- Modify: `SketchCamCore/Sources/CoreImageFrameProcessor.swift`

- [ ] **Step 1: Materialize Acrylic streams by node ID**

Extend compositor stream lookup with `acrylicImages: [UUID: CIImage]`. For `.acrylic`, return the matching engine image. Do not flatten Acrylic nodes before graph order, opacity, mask, effects, and blend are applied.

- [ ] **Step 2: Verify ordering**

Test Acrylic above Ink covers it, Acrylic below Ink remains behind it, two Acrylic nodes composite independently, and deleting one node releases only its engine.

- [ ] **Step 3: Commit compositing**

Commit with `git commit -m "Composite acrylic layer sources"`.

### Task 7: Add Acrylic editor controls

**Files:**
- Modify: `SketchCam/App/ContentView.swift`

- [ ] **Step 1: Add Acrylic to Add Layer and source selection**

Create a node with `AcrylicConfig()` and a normal visible Layer. Expanding that layer shows color, Body, mixing model, and primary size/loading controls.

- [ ] **Step 2: Add the dedicated Acrylic tab**

Show selected-layer picker, Clear, Instant Dry, Rerender, Save, undo/redo, color, size, Body, and mix model. Put pigment opacity, viscosity, leveling, retention, loading, flow, Dry Rate, Paper Influence, Live Surface, Live → Absorbency/Drag/Resist weights, and Motion Force in a collapsed Advanced section. Default live weights match Ink: `0`, `0.5`, and `1`.

- [ ] **Step 3: Preserve macro semantics**

Call `applyBody` only when the Body slider changes. Editing an advanced value must not recompute siblings; moving Body later reapplies the coordinated set.

- [ ] **Step 4: Visually verify and commit**

Check glaze/fluid/heavy endpoints, multiple Acrylic layers, and overpainting controls. Commit with `git commit -m "Expose acrylic painting controls"`.

### Task 8: Full verification

**Files:**
- Test: `Tests/SketchCamCoreTests/LayerGraphTests.swift`

- [ ] Run direct Core tests and the unsigned Debug app build.
- [ ] Verify retained-stroke replay is deterministic for both mixing models.
- [ ] Verify gradual drying, zero Dry Rate, Instant Dry, and overpainting dried Acrylic.
- [ ] Verify disabled/absent Acrylic allocates no textures and adds no frame work.
- [ ] Record Ink, control-field, motion, and Acrylic timings with representative 1080p output.
- [ ] Run `git diff --check`; commit only verification fixes.
