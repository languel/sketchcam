# GPU Control Fields Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persisted, typed control-field graph and a GPU-resident runtime registry that can route scalar and vector textures to simulations without changing current output.

**Architecture:** Keep visible pixel/path routing in `LayerGraph` and introduce a parallel `ControlFieldGraph` for named scalar/vector outputs. `GPUControlFieldStore` owns lazy zero textures and published provider textures; `ControlFieldCoordinator` resolves settings into runtime fields once per frame.

**Tech Stack:** Swift 5, Metal compute, Core Video, XcodeGen, XCTest.

---

### Task 1: Define the persisted field graph

**Files:**
- Create: `SketchCamCore/Sources/ControlFieldGraph.swift`
- Modify: `SketchCamCore/Sources/ProcessingSettings.swift`
- Create: `Tests/SketchCamCoreTests/ControlFieldGraphTests.swift`

- [ ] **Step 1: Write failing model and validation tests**

Add tests that construct scalar/vector provider outputs, reject a scalar-to-vector route, reject a dangling provider, reject a provider-input cycle, and decode `{}` with an empty graph. Use fixed UUIDs and assert `ControlFieldGraphError` values exactly.

```swift
func testRejectsMismatchedRouteKind() {
    let provider = ControlFieldProvider(name: "Paper", kind: .paper)
    let route = ControlFieldRoute(
        consumer: .ink,
        input: .motionVector,
        source: .init(provider: provider.id, output: .paperAbsorbency)
    )
    XCTAssertThrowsError(try ControlFieldGraph(providers: [provider], routes: [route]).validate()) {
        XCTAssertEqual($0 as? ControlFieldGraphError, .kindMismatch(route: route.id))
    }
}
```

- [ ] **Step 2: Run the test target and verify the new file fails to compile**

Run:

```bash
xcodegen generate
xcodebuild -project SketchCam.xcodeproj -target SketchCamCoreTests -configuration Debug -derivedDataPath /tmp/sketchcam-control-fields build CODE_SIGNING_ALLOWED=NO
```

Expected: failure because `ControlFieldProvider`, `ControlFieldRoute`, and `ControlFieldGraph` do not exist.

- [ ] **Step 3: Add the complete Core model**

Define `ControlFieldKind`, stable output/input identifiers, provider kinds, references, routes, and graph validation. Use these public shapes so later plans do not rename them:

```swift
public enum ControlFieldKind: String, Codable, Sendable { case scalar, vector }
public enum ControlFieldOutputID: String, Codable, Sendable, CaseIterable {
    case paperAbsorbency, paperDrag, paperResist, motionMagnitude, motionVector
    public var kind: ControlFieldKind { self == .motionVector ? .vector : .scalar }
}
public enum ControlFieldInputID: String, Codable, Sendable, CaseIterable {
    case absorbency, drag, resist, surfaceModulation, motionVector
    public var kind: ControlFieldKind { self == .motionVector ? .vector : .scalar }
}
public enum ControlFieldProviderKind: String, Codable, Sendable { case paper, trackedMotion, opticalFlow, combinedMotion }
public enum ControlFieldUpdateQuality: String, Codable, Sendable, CaseIterable { case low, medium, high }
public enum ControlFieldConsumerID: Codable, Sendable, Hashable { case ink; case acrylic(UUID) }
public struct ControlFieldReference: Codable, Sendable, Equatable, Hashable {
    public var provider: UUID
    public var output: ControlFieldOutputID
    public init(provider: UUID, output: ControlFieldOutputID) {
        self.provider = provider; self.output = output
    }
}
public struct ControlFieldProvider: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: ControlFieldProviderKind
    public var enabled: Bool
    public var quality: ControlFieldUpdateQuality
    public var inputs: [ControlFieldReference]
    public init(id: UUID = UUID(), name: String, kind: ControlFieldProviderKind,
                enabled: Bool = true, quality: ControlFieldUpdateQuality = .low,
                inputs: [ControlFieldReference] = []) {
        self.id = id; self.name = name; self.kind = kind
        self.enabled = enabled; self.quality = quality; self.inputs = inputs
    }
}
public struct ControlFieldRoute: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var consumer: ControlFieldConsumerID
    public var input: ControlFieldInputID
    public var source: ControlFieldReference
    public var strength: Float
    public var invert: Bool
    public var threshold: Float
    public init(id: UUID = UUID(), consumer: ControlFieldConsumerID, input: ControlFieldInputID,
                source: ControlFieldReference, strength: Float = 1, invert: Bool = false,
                threshold: Float = 0) {
        self.id = id; self.consumer = consumer; self.input = input; self.source = source
        self.strength = strength; self.invert = invert; self.threshold = threshold
    }
}
public struct ControlFieldGraph: Codable, Sendable, Equatable {
    public var providers: [ControlFieldProvider]
    public var routes: [ControlFieldRoute]
    public init(providers: [ControlFieldProvider] = [], routes: [ControlFieldRoute] = []) {
        self.providers = providers; self.routes = routes
    }
    public static let empty = ControlFieldGraph()
    public func validate() throws
}
```

Provider outputs are fixed by kind: Paper publishes the three paper scalars; Tracked Motion and Optical Flow publish magnitude/vector; Combined Motion publishes magnitude/vector and consumes one tracked and one optical-flow reference. Validation confirms referenced outputs exist before type and cycle checks.

Add optional `controlFields: ControlFieldGraph?` to `ProcessingSettings`; nil resolves to `.empty`. Preserve synthesized decoding by making the field optional and defaulting the initializer argument to nil. Provider quality controls live update resolution/cadence; static Paper providers ignore it.

- [ ] **Step 4: Run tests and commit the model**

Run the build command from Step 2, then:

```bash
xcrun xctest /tmp/sketchcam-control-fields/Build/Products/Debug/SketchCamCoreTests.xctest
git add SketchCamCore/Sources/ControlFieldGraph.swift SketchCamCore/Sources/ProcessingSettings.swift Tests/SketchCamCoreTests/ControlFieldGraphTests.swift SketchCam.xcodeproj
git commit -m "Add typed control field graph"
```

Expected: all Core tests pass.

### Task 2: Add the GPU field registry

**Files:**
- Create: `SketchCam/Metal/GPUControlFieldStore.swift`
- Create: `SketchCam/Metal/ControlFieldShaders.metal`
- Modify: `project.yml`

- [ ] **Step 1: Add a debug-only failing registry self-check**

Create `GPUControlFieldStore.runSelfCheck()` under `#if DEBUG` and assert that missing scalar/vector references resolve to correctly formatted zero textures, published revisions replace older revisions, and `remove(provider:)` removes every output.

- [ ] **Step 2: Implement the registry and immutable field handle**

Use this runtime interface:

```swift
struct GPUControlField {
    let kind: ControlFieldKind
    let texture: MTLTexture
    let revision: UInt64
}

final class GPUControlFieldStore {
    init?(device: MTLDevice)
    func publish(_ field: GPUControlField, provider: UUID, output: ControlFieldOutputID)
    func resolve(_ reference: ControlFieldReference, width: Int, height: Int) -> GPUControlField
    func zero(kind: ControlFieldKind, width: Int, height: Int) -> GPUControlField
    func remove(provider: UUID)
    func reset()
}
```

Allocate scalar textures as `.r16Float` and vectors as `.rg16Float`, private storage, shader read/write usage. Cache one zero texture per kind and dimensions. Clear a zero texture exactly once with `control_clear_scalar` or `control_clear_vector`; do not allocate or encode during later resolves.

- [ ] **Step 3: Register files and build**

Run:

```bash
xcodegen generate
xcodebuild -project SketchCam.xcodeproj -scheme SketchCam -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/sketchcam-control-fields-app build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`, including the debug self-check.

- [ ] **Step 4: Commit the GPU registry**

```bash
git add SketchCam/Metal/GPUControlFieldStore.swift SketchCam/Metal/ControlFieldShaders.metal project.yml SketchCam.xcodeproj
git commit -m "Add GPU control field registry"
```

### Task 3: Resolve fields once per frame

**Files:**
- Create: `SketchCam/Metal/ControlFieldCoordinator.swift`
- Modify: `SketchCam/App/SketchCamViewModel.swift`
- Modify: `SketchCam/Diagnostics/PipelineTimings.swift`

- [ ] **Step 1: Add coordinator contract and a disabled-path assertion**

Define provider implementations behind this protocol:

```swift
protocol GPUControlFieldProvider: AnyObject {
    var id: UUID { get }
    var outputs: Set<ControlFieldOutputID> { get }
    func update(_ context: ControlFieldFrameContext, store: GPUControlFieldStore)
    func reset(store: GPUControlFieldStore)
}
```

`ControlFieldFrameContext` contains the frame index, timestamp, output dimensions, camera/movie pixel buffers, and current `LandmarkDetection?`. In DEBUG, assert that an empty graph causes zero provider updates and no new textures after the first zero resolve.

- [ ] **Step 2: Implement graph reconciliation**

`ControlFieldCoordinator.update(graph:context:)` validates the graph, creates providers only for enabled settings, updates only providers with an active route, removes stale providers, and returns a `ResolvedControlFields` lookup keyed by `(consumer,input)`. Invalid graphs log once and resolve all routes to zero rather than aborting frame processing.

- [ ] **Step 3: Integrate after detection and before Ink**

In `SketchCamViewModel.process`, retain the frame's `LandmarkDetection?`, call the coordinator after detection/overlay preparation, and pass `ResolvedControlFields` into `InkLayerCompositor.layer`. Do not alter Ink yet; the compositor accepts and ignores the new argument until the paper/motion plan.

Add timing cases `.controlFields`, `.paperFields`, `.motion`, and `.acrylic` with display names. Record only `.controlFields` in this plan.

- [ ] **Step 4: Build, smoke test, and commit**

Run the Core tests and unsigned app build. Launch the app once with Ink enabled and confirm the performance overlay reports Control Fields near zero with an empty graph.

```bash
git add SketchCam/Metal/ControlFieldCoordinator.swift SketchCam/App/SketchCamViewModel.swift SketchCam/Landmarks/InkLayerCompositor.swift SketchCam/Diagnostics/PipelineTimings.swift SketchCam.xcodeproj
git commit -m "Integrate control fields into frame pipeline"
```

### Task 4: Final compatibility verification

**Files:**
- Test: `Tests/SketchCamCoreTests/ControlFieldGraphTests.swift`

- [ ] **Step 1: Verify legacy decoding and graph validation**

Run the Core test bundle and confirm old `ProcessingSettings` JSON decodes with no providers or routes.

- [ ] **Step 2: Verify the current Ink baseline**

Build and launch with an empty control graph. Compare a fixed-seed Ink scene before/after this plan; output must be pixel-identical and the engine must not encode control-field passes.

- [ ] **Step 3: Check repository hygiene and commit fixes only if needed**

```bash
git diff --check
git status --short
```

Expected: only the intentionally untracked `.superpowers/` companion may remain.
