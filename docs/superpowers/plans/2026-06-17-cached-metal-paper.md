# Cached Metal Paper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one cached procedural Metal paper renderer used independently by Ink's internal substrate and any number of Paper source nodes, while preserving the current internal paper as the exact default and moving Add Layer into the stack header.

**Architecture:** `PaperConfig` becomes the complete serializable paper recipe, with legacy fields retained for decoding. A focused `MetalPaperRenderer` owns cached GPU textures keyed by resolved configuration and output dimensions. The Ink display kernel samples the cached paper texture; layer-graph Paper nodes expose the same cached renderer through a materialized `CIImage` path.

**Tech Stack:** Swift 5, Metal compute shaders, Core Image, Core Video pixel buffers, SwiftUI, XcodeGen/XCTest.

---

### Task 1: Expand and normalize the paper model

**Files:**
- Modify: `SketchCamCore/Sources/LayerGraph.swift`
- Modify: `SketchCamCore/Sources/ProcessingSettings.swift`
- Test: `Tests/SketchCamCoreTests/LayerGraphTests.swift`

- [ ] Add optional persisted fields to `PaperConfig`: `contrast`, `fiberStrength`, `fiberScaleX`, `fiberScaleY`, `fiberOrientation`, `toothStrength`, `toothScaleX`, `toothScaleY`, `grainScaleX`, `grainScaleY`, `seed`, and `vignetteStrength`. Keep `grain`, `scale`, and `texture` so old payloads decode.
- [ ] Add `PaperConfig.metalDefault`, whose resolved values exactly encode the current shader constants: tint `(0.962, 0.954, 0.930, 1)`, fiber strength `0.05` at `0.055`, tooth strength `0.022` at `0.42`, grain strength `0.45` at `0.12`, seed `0`, contrast `1`, and vignette `0.16`.
- [ ] Add a `ResolvedPaperConfig: Hashable, Sendable` value and `PaperConfig.resolved` conversion. Missing new fields map deterministically from legacy Fiber/Speckle/Wash values; new configurations use the Metal defaults.
- [ ] Add optional `inkPaperConfig: PaperConfig?` to `LandmarkSettings`. Its fallback is `.metalDefault` with legacy `inkPaperGrain`, `inkPaperColor`, and `inkPaperOpacity` applied where those settings were effective.
- [ ] Add XCTest cases asserting exact Metal defaults, stable hash/equality, and decoding of a legacy JSON PaperConfig without new keys.
- [ ] Run `xcodegen generate` and `xcodebuild -project SketchCam.xcodeproj -scheme SketchCam -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`; expect `BUILD SUCCEEDED`.
- [ ] Commit with `git commit -m "Expand procedural paper configuration"`.

### Task 2: Implement the cached Metal paper renderer

**Files:**
- Create: `SketchCam/Metal/MetalPaperRenderer.swift`
- Modify: `SketchCam/Metal/InkWashShaders.metal`

- [ ] Add an `ink_generate_paper` compute kernel. It receives resolved tint, contrast, fiber/tooth/grain strengths and X/Y frequencies, fiber orientation, seed, and vignette. Extract the existing `fbm`/`vnoise` paper calculation from `ink_display` without changing default arithmetic.
- [ ] Implement `MetalPaperRenderer` with a `CacheKey` containing `ResolvedPaperConfig`, width, height, and pixel format. Cache one texture per distinct active key and expose `texture(config:size:commandBuffer:)` for Ink.
- [ ] Add `image(config:rect:)` for layer sources. It creates or reuses an IOSurface-backed BGRA pixel buffer, encodes generation only on a cache miss, and returns a cropped materialized `CIImage`.
- [ ] Add debug-only counters `generationCount` and `cacheHitCount`, then add focused tests or a debug self-test proving identical requests reuse the cached allocation and a changed seed regenerates.
- [ ] Build with the project-native Xcode command and expect `BUILD SUCCEEDED`.
- [ ] Commit with `git commit -m "Add cached Metal paper renderer"`.

### Task 3: Make Ink sample the cached paper

**Files:**
- Modify: `SketchCam/Landmarks/MetalInkEngine.swift`
- Modify: `SketchCam/Metal/InkWashShaders.metal`
- Modify: `SketchCam/Landmarks/InkLayerCompositor.swift`

- [ ] Give `MetalInkEngine` a `MetalPaperRenderer` using the engine's device.
- [ ] Replace `DisplayParams` paper noise fields with substrate-compositing fields and bind the renderer's cached paper texture to `ink_display`.
- [ ] Remove procedural paper generation from `ink_display`; retain pigment absorption, edge enhancement, wet tint, opacity, and Clear fade behavior while sampling the generated paper RGB.
- [ ] Resolve the internal config from `landmarks.inkPaperConfig ?? .metalDefault`, applying paper opacity separately. When an external texture is routed into Ink, keep the current behavior of disabling the internal substrate.
- [ ] Add a debug comparison that renders the old default constants and new `.metalDefault` at representative points within a small tolerance, or preserve the old expression in a test-only reference helper.
- [ ] Build and run the Metal ink self-test; expect no initialization or rendering failures.
- [ ] Commit with `git commit -m "Use cached paper in Metal ink"`.

### Task 4: Replace Core Image Paper sources

**Files:**
- Modify: `SketchCam/App/SketchCamViewModel.swift`
- Modify: `SketchCamCore/Sources/LayerGraph.swift`

- [ ] Add a view-model-owned `MetalPaperRenderer` for layer graph sources.
- [ ] Replace `paperImage(config:rect:)` and its `CIRandomGenerator`/blur branches with `metalPaperRenderer.image(config:rect:)` in both CPU and GPU graph-resolution paths.
- [ ] Ensure each Paper node passes its own configuration; identical configurations may share a cache entry, while different seed/scale/tint values produce independent keys.
- [ ] Remove obsolete Core Image PaperTexture rendering code but retain legacy enum decoding in the model.
- [ ] Build and verify a graph containing two differently configured Paper nodes resolves two images without recursive CI growth.
- [ ] Commit with `git commit -m "Render layer paper sources with Metal"`.

### Task 5: Expose identical paper controls

**Files:**
- Modify: `SketchCam/App/ContentView.swift`

- [ ] Add a reusable `PaperControls` SwiftUI view bound to `PaperConfig`. Group controls as Base, Fiber, Tooth, and Grain; expose tint, opacity where owned by the caller, contrast, strengths, separate X/Y scales, fiber orientation, seed, and vignette.
- [ ] Replace the Paper node's Fiber/Speckle/Wash segmented control and old Scale/Grain rows with `PaperControls`.
- [ ] Replace Ink's Tint/Grain-only controls with the same `PaperControls`, binding through `landmarks.inkPaperConfig`. Keep Ink's substrate opacity control separate and disable internal-paper controls when a texture input is routed.
- [ ] Ensure creating a new Paper layer initializes `.paper(.metalDefault)` and creating/resetting Ink uses the same `.metalDefault` values independently.
- [ ] Build and inspect the expanded controls at the existing side-panel width; labels and numeric fields must remain readable without horizontal clipping.
- [ ] Commit with `git commit -m "Expose procedural Metal paper controls"`.

### Task 6: Move Add Layer into the stack header

**Files:**
- Modify: `SketchCam/App/ContentView.swift`

- [ ] Locate the layer-stack header and move the existing Add Layer menu beside `LAYER STACK`, preserving every source action and disabled state.
- [ ] Remove the old bottom menu so only one Add Layer affordance remains.
- [ ] Verify the menu opens downward from the header and remains reachable with a long, scrolled layer list.
- [ ] Build and visually compare against the supplied screenshot: Add Layer follows the header text rather than appearing beneath Camera.
- [ ] Commit with `git commit -m "Move add layer menu to stack header"`.

### Task 7: Final compatibility and performance verification

**Files:**
- Modify if needed: `Tests/SketchCamCoreTests/LayerGraphTests.swift`
- Modify if needed: `SketchCam/Metal/MetalPaperRenderer.swift`

- [ ] Load or decode legacy graphs containing Fiber, Speckle, and Wash Paper nodes; expect valid resolved configurations and no missing-key failures.
- [ ] Verify `.metalDefault` in Ink and a standalone Paper node produce matching substrate pixels at the same size and opacity.
- [ ] Run a sustained preview with unchanged paper settings and confirm `generationCount` remains constant after the initial render.
- [ ] Change tint, one X scale, orientation, and seed independently; confirm exactly one cache miss per change and visibly distinct output.
- [ ] Run `git diff --check` and the full unsigned Debug build; expect no whitespace errors and `BUILD SUCCEEDED`.
- [ ] Commit any verification fixes with `git commit -m "Verify cached Metal paper pipeline"`.
