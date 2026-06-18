# Paper Substrate Compositing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add collapsible Ink paper controls, tint-relative contrast and saturation, Soft Light blending, and configurable cached-paper composition over routed Ink substrates.

**Architecture:** Extend persisted paper and Ink settings with backward-compatible optional fields. Reuse the existing cached paper texture and existing compositing infrastructure; combine routed substrates with paper only after paper generation so animated inputs never invalidate the paper cache.

**Tech Stack:** Swift 5, SwiftUI, Metal compute shaders, Core Image, XcodeGen/XCTest.

---

### Task 1: Extend paper and blend models

**Files:**
- Modify: `SketchCamCore/Sources/LayerGraph.swift`
- Modify: `SketchCamCore/Sources/ProcessingSettings.swift`
- Test: `Tests/SketchCamCoreTests/LayerGraphTests.swift`

- [ ] Add `softLight` to `BlendMode` and its title mapping.
- [ ] Add optional `saturation` to `PaperConfig`, default/resolved value 1, and `ResolvedPaperConfig` hashing.
- [ ] Add `InkPaperCompositeMode` with `none` plus all supported straight-color modes, and optional `inkPaperCompositeMode` defaulting to Multiply.
- [ ] Add model tests for legacy decoding and defaults.
- [ ] Build and commit with `git commit -m "Extend paper compositing models"`.

### Task 2: Correct paper color shaping

**Files:**
- Modify: `SketchCam/Metal/MetalPaperRenderer.swift`
- Modify: `SketchCam/Metal/InkWashShaders.metal`

- [ ] Pass saturation through the cached paper generation parameters.
- [ ] Change contrast pivot from 0.5 to configured tint, then apply luminance-based saturation.
- [ ] Preserve output clamping and alpha.
- [ ] Build and commit with `git commit -m "Improve procedural paper color controls"`.

### Task 3: Implement Soft Light and routed substrate mixing

**Files:**
- Modify: `SketchCam/Metal/EffectShaders.metal`
- Modify: `SketchCam/Metal/MetalEffects.swift`
- Modify: `SketchCam/App/SketchCamViewModel.swift`
- Modify: `SketchCam/Landmarks/InkLayerCompositor.swift`

- [ ] Implement premultiplied-aware Soft Light in the shared Metal blend shader and assign a stable blend code.
- [ ] Add equivalent Core Image blend filter routing for the CPU graph path.
- [ ] In `InkLayerCompositor`, combine routed texture and cached paper using the selected Ink substrate mode before placing ink over it; None bypasses paper.
- [ ] Ensure routed frames do not alter the paper cache key.
- [ ] Build and commit with `git commit -m "Composite paper over routed ink substrates"`.

### Task 4: Update paper controls

**Files:**
- Modify: `SketchCam/App/ContentView.swift`

- [ ] Increase paper Contrast sliders to 0 through 4 and add Saturation 0 through 2.
- [ ] Put expanded Ink paper parameters in a collapsed `DisclosureGroup` while leaving input, enable, opacity, and blend visible.
- [ ] Add the substrate blend dropdown with None and all supported modes; default routed selection is Multiply.
- [ ] Add Soft Light to ordinary layer blend menus.
- [ ] Build and visually verify the Ink and Layers panels.
- [ ] Commit with `git commit -m "Refine paper controls and substrate blending"`.

### Task 5: Verify

**Files:**
- Modify if required: `Tests/SketchCamCoreTests/LayerGraphTests.swift`

- [ ] Run the complete Xcode test bundle and unsigned Debug build.
- [ ] Verify Contrast 1/Saturation 1 preserves default appearance, Contrast above 1 strengthens texture without whitening, and Saturation 0 is grayscale.
- [ ] Verify None, Multiply, Overlay, and Soft Light routed-substrate behavior and stable paper cache generation.
- [ ] Run `git diff --check`, regenerate the Xcode project if necessary, and commit verification fixes.
