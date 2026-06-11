# Performance deep-dive and optimization plan

Context (2026-06-11): the `codex/mediapipe-landmark-yarn` working tree added a
landmark overlay ("yarn" doodle, MediaPipe-style) and processing throughput
collapsed to ~1 fps. An equivalent p5.js + MediaPipe sketch runs ~30 fps in a
browser, so this is not an inherent cost of the idea — the native pipeline is
doing structurally expensive things per frame. This document is the code-level
audit and the plan.

## Why ~1 fps is plausible from the code alone

Per camera frame, the current hot path does ALL of the following:

| # | Cost | Where |
|---|---|---|
| 1 | **5+ `DispatchQueue.main.sync` round-trips** | `settingsSnapshot()`/`outputFormatSnapshot()`/`permissionSnapshot()` are each `main.sync`. Called in `handleCameraSample` (camera queue!), again in `process()`, and twice more in `publish()` (SketchCamViewModel.swift) |
| 2 | **2–3 GPU→CPU readbacks at full output resolution** | `LandmarkOverlayRenderer.drawBase` (`createCGImage` of the 1080p processed frame), `PreviewRenderer.makeImage` (another 1080p `createCGImage`), every frame |
| 3 | **3–4 fresh `CVPixelBuffer` (IOSurface) allocations** | `CoreImageFrameProcessor.render`, `LandmarkOverlayRenderer.render`, `makeLandmarkDetectionBuffer`, `VisionLandmarkTracker.downsampled` — no `CVPixelBufferPool` anywhere |
| 4 | **CPU vector drawing at 1080p** | overlay yarn/raw drawing into a locked pixel buffer via `CGContext`, re-done every frame even when the cached landmarks haven't changed |
| 5 | **New `CMVideoFormatDescription` + `CMSampleBuffer`** | `PixelBufferUtils.makeSampleBuffer` re-derives the format description per frame |
| 6 | **6 `@Published` mutations + a full-res `CGImage` into SwiftUI** | `publish()` → main thread re-renders `ContentView` (sliders, grids) at frame rate |

The killer is the *feedback loop between #1 and #6*: every published frame
floods the main thread with SwiftUI work (including a 1080p CGImage), and the
processing/camera threads block in `main.sync` waiting for that same main
thread. Latency compounds; the `frameGate` then drops everything while one
frame crawls through. 1 fps is the steady state of that loop, with the
readbacks and allocations (#2–4) setting the floor.

Secondary, but real:

- **5 separate `CIContext`s** (processor, view model, overlay, preview, vision
  tracker), all with `cacheIntermediates: false` — no shared resources, extra
  GPU sync, no intermediate caching.
- The 30 Hz test-pattern timer keeps running while the camera is live, doing
  two more `main.sync`s per tick before bailing out.
- Vision detection (`VNDetectHumanBodyPoseRequest` + hand + face) is decently
  architected already (separate queue, frame-interval throttle, downsampled
  input) but re-creates request objects per detection, double-downsamples
  (view model AND tracker), and pins nothing (`revision`, hand count 2).
- The MediaPipe tracker is a stub — all real detection is Apple Vision. The
  browser comparison point uses MediaPipe WASM+GPU at ~256 px input with GPU
  canvas compositing; our pipeline pays 1080p CPU compositing.

## Targets

At 1920×1080/30 fps output on Apple silicon:

| Stage | Budget |
|---|---|
| CI filter chain (threshold+edges) render | ≤ 6 ms GPU |
| Landmark overlay composite | ≤ 2 ms GPU (no readback in hot path) |
| Publish (sink enqueue) | ≤ 0.5 ms |
| Preview | throttled to ≤ 15 Hz, downscaled to view size, ≤ 3 ms |
| Detection (off hot path) | 30–80 ms per run, 1 in N frames, never blocking publish |
| **Total hot path** | **≤ 12 ms/frame → solid 30 fps with headroom** |

## Plan

### Phase 0 — branch hygiene + measurement harness (do first)

1. Commit the **distribution pipeline work** (project.yml, script/*, notes,
   `VirtualCameraFramePublisher` queue-proc fix) from this tree onto `main` —
   that's the "working minimal extension" baseline. Commit the landmark
   experiment separately onto `codex/mediapipe-landmark-yarn` so nothing is
   lost, then branch `perf/pipeline` from `main`.
2. Add `os_signpost` intervals around: capture→dispatch, CI render, overlay,
   publish, preview, detection. Add per-stage ms to the Debug grid (rolling
   average). All later phases are judged against this. Acceptance: numbers
   visible in-app and in Instruments without guesswork.

### Phase 1 — remove the structural stalls (biggest win, no visual change)

1. **Kill `main.sync` snapshots.** Keep a lock-protected (or
   `OSAllocatedUnfairLock`) copy of `ProcessingSettings`/`FrameFormat`
   that the UI writes and the pipeline reads. One snapshot per frame, taken
   once at the top of `process()` and passed down (no re-reading in
   `publish`).
3. **One shared `CIContext`** for processor/overlay/preview/downsampler,
   created once with `cacheIntermediates: true`.
2. **`CVPixelBufferPool` per (stage, format)** with a cached
   `CMVideoFormatDescription`; recreate only on format change. Pools for:
   processor output, overlay output, detection downsample.
4. **Decouple preview from publish.** Publish every frame; update
   `previewImage` at most ~12–15 Hz and render it at the preview view's pixel
   size, not 1080p. (Later: replace CGImage preview with
   `AVSampleBufferDisplayLayer`/`MTKView` fed directly — zero readback.)
5. Batch the Debug-grid stats into one `@Published` struct updated at ~4 Hz.
6. Stop the test-pattern timer while the camera is the active source.

Expected outcome: effect-only pipeline (no landmarks) back to a stable 30 fps;
landmark pipeline limited only by the overlay (Phase 2).

### Phase 2 — overlay rendering on the GPU path

1. Render landmark graphics **only when the cached landmark set changes**
   (detection cadence, not frame cadence) into a small transparent CGBitmap
   (it's vector dots/curves — 1280×720 is plenty), wrap as `CIImage`, cache.
2. Composite cached overlay over the processed frame with `sourceOver` inside
   the existing CI render — no readback, no per-frame CPU drawing, no second
   output buffer (single render into the pooled output).
3. Optional polish: motion-interpolate cached landmark positions between
   detections (cheap CPU math on ≤100 points) so the overlay stays lively at
   30 fps even with detection at 5–10 Hz.

### Phase 3 — the control matrix (toggle/bypass everything)

UI section "Performance" + plumbing so every stage is individually
bypassable and the bypass is genuinely zero-cost (no allocation, no render):

| Control | Notes |
|---|---|
| Master bypass (passthrough) | camera → publish untouched (aspect-fill only) |
| Effect layers on/off (exists) | when off: skip CI chain entirely — verify no-op cost |
| Threshold / outline layers (exist) | already conditional; keep |
| Landmark overlay on/off (exists) | off must also stop detection submissions |
| Per-region tracking toggles (exist) | face / hands / body / eyes |
| Detection rate | slider 1–15 Hz (exists as interval; expose clearly) |
| Detection input size | 256 / 384 / 512 (exists via quality; expose directly) |
| Input resolution (exists: 352/640/720p/native) | add 320×240; default VGA |
| **Processing resolution** (new) | process+overlay at 540p/720p, single upscale at the end; output format stays 1080p for clients |
| Output resolution (exists: 360/720/1080) | expose in UI next to the rest |
| Preview mode (exists) + **preview off / preview rate** (new) | preview off = zero preview cost while publishing |
| Per-stage ms readout (Phase 0) | so the user can SEE what each toggle buys |

### Phase 4 — detection backend

1. Vision tuning: reuse request instances, pin `revision`, hand count 1 by
   default, drop the tracker's internal second downsample (the view model
   already downsamples), consider `VNDetectFaceLandmarksRequest` constellation
   76 only when eyes enabled.
2. MediaPipe (the actual goal): MediaPipe Tasks Vision has no official macOS
   binary — that's why the current tracker is a stub. Two viable routes, to
   evaluate AFTER the pipeline is fast with Vision (the pipeline fixes benefit
   any backend):
   a. Build `mediapipe` C/C++ task runners for macOS (bazel; doable, heavy).
   b. Keep Vision as the native backend and accept it as "the macOS
      holistic" — it already covers face/eyes/hands/body and runs on ANE.
   Decision point at end of Phase 3 with real numbers.

### Phase 5 — regression guards

- Perf smoke test target: feed N synthetic 1080p frames through the processor
  (+ overlay with synthetic landmarks) and assert ≥ 25 fps equivalent.
- Keep the per-stage ms HUD; document expected numbers in this file.

## Branch strategy (per discussion)

```
main ──► commit signing/distribution work (from this tree)   ← "working minimal extension"
   └──► perf/pipeline        ← Phases 0–3 fresh, no landmark code initially
            └─ landmark overlay re-lands as Phase 2/3 features, ported
               selectively from codex/mediapipe-landmark-yarn (keep:
               LandmarkTrackingService throttling design, yarn renderer
               visuals; drop: per-frame CPU compositing)
codex/mediapipe-landmark-yarn ──► commit as-is for reference, then freeze
```

## File-level pointers for the fixes

- `SketchCam/App/SketchCamViewModel.swift` — main.sync snapshots (`settingsSnapshot` etc.), duplicate snapshot calls in `publish`, test-pattern timer, stats flooding.
- `SketchCam/Landmarks/LandmarkOverlayRenderer.swift` — per-frame readback (`drawBase`) + CPU drawing; becomes cached-CIImage composite.
- `SketchCamCore/Sources/CoreImageFrameProcessor.swift` — per-frame `makePixelBuffer`; takes a pool + shared context; add processing-resolution support.
- `SketchCamShared/Sources/PixelBufferUtils.swift` — add pool-based allocation + cached format descriptions.
- `SketchCam/Preview/PreviewRenderer.swift` — downscale + throttle; later replace with a layer-based preview.
- `SketchCam/Landmarks/VisionLandmarkTracker.swift` — request reuse, drop double downsample.

---

## Results (2026-06-11, perf/pipeline)

Phases 0, 1, and 3 are implemented on this branch. Measured live (Debug
build, VGA input, 1080p output, full effects, publishing to the activated
extension, Photo-Booth-class consumer attached):

| Metric | Before (yarn branch) | After |
|---|---|---|
| End-to-end FPS | ~1 | **30.2** (camera-locked) |
| Frame total | ~1000 ms | **2.2 ms** |
| Process (CI chain + render) | — | 1.5 ms |
| Preview readback (12 Hz, ≤960 px) | full-res every frame | 2.0 ms |
| Snapshot / Publish | main.sync per frame | 0.0 ms |

Headless throughput guards (Debug, `ProcessorThroughputTests`, written to
`/tmp/sketchcam-perf.txt`):

| Path | ms/frame |
|---|---|
| full effects 1080p | 0.78 |
| full effects @540p→1080p | 0.75 |
| threshold-only 1080p | 0.53 |
| full effects 720p | 0.53 |
| passthrough 1080p | 0.45 |

Remaining phases when landmarks land on this base: Phase 2 (overlay as
cached CIImage composite, rendered at detection cadence) and Phase 4
(detection backend tuning). The Phase 1/3 infrastructure (state store,
pools, shared context, preview throttle, bypass matrix, stage HUD) is what
they build on.

## Results: Phases 2+4 (landmark overlay, 2026-06-11)

Live measurement (Debug build, camera source, Vision detection at 10 Hz,
yarn overlay enabled, VGA input, 1080p output, publishing):

| Metric | yarn branch | perf/pipeline |
|---|---|---|
| FPS with landmark overlay | ~1 | **30.0** (camera-locked) |
| Frame total | ~1000 ms | **3.6–4.8 ms** |
| Overlay stage (cached composite + periodic re-render) | full CPU redraw/frame | 2.0–2.5 ms |
| Detect (off hot path, own queue) | blocking-adjacent | 14.7–18.7 ms @ 10 Hz |
| App CPU | — | ~37% |

Throughput guard: full effects + overlay composite 1080p = 0.83 ms/frame.

Also fixed: changing the app's output resolution no longer produces the
fallback stripes in consumers — the extension now rescales host frames to
the consumer-negotiated format (FrameScaler) instead of dropping them.
NOTE: the extension fix ships with the next release build
(script/release_build.sh + notarize + install) — the installed extension
predates it.

Dev affordances: `SKETCHCAM_LANDMARKS=camera|synthetic` env var or
`defaults write io.github.languel.sketchcam SKETCHCAM_LANDMARKS camera`
enables the overlay at launch; DEBUG builds append 5-second perf lines to
`~/Library/Containers/io.github.languel.sketchcam/Data/tmp/sketchcam-perf-live.txt`.
