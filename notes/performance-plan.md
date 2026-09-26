# Current performance and filter-only workflow

This note records the current performance controls and the optimization pass
that followed the 2026-08-21 live measurement. The older, detailed phase plan
and historical measurements remain in
[`notes/old/performance-plan.md`](old/performance-plan.md).

## What the performance panel means

The Performance panel reports both the frame cadence and the latest measured
or cached analysis durations:

Open it with **Control–Option–P** or the chart-shaped **Performance** button in
the window controls. Its FPS is the video pipeline cadence, not a separate
SwiftUI canvas-navigation frame counter. If zoom/pan stutters while this FPS
stays high, investigate the UI path rather than attributing the stall to
Vision or the compositor.

- **Process** is the compositor/effect stage for the current frame.
- **Frame total** includes the full frame-loop work, including source routing,
  overlay preparation, and publishing.
- **Detect** and **Segment** report the most recent off-path Vision/landmark
  run. They may remain non-zero after the corresponding work has been disabled
  until a new sample is recorded; use Frame total and Process to judge the
  current frame path.

A prior filter-heavy session showed roughly 10.6 FPS, 39.8 ms Process,
14.3 ms Detect, and 12.1 ms Segment at 1920×1080 output. Those numbers are a
diagnostic baseline, not a hardware-independent guarantee.

## Filter-only tuning

For a stack made only from Threshold, Levels/Gain, Stripes, Stipple, Duotone,
Pixel dots, or other image effects:

1. Keep **GPU compositor (experimental)** enabled.
2. Choose **Processing** → **720p** or **540p** while leaving the published
   **Output** format unchanged.
3. In **Analysis**, turn off **Live feature analysis**. This bypasses
   landmark detection, contour construction, and automatic person-matte
   requests.
4. Turn off **Segmentation / person matte** as well when no Person Key or
   matte-backed mask is being tuned.
5. Compare **Process**, **Frame total**, and FPS in the Performance panel while
   enabling one effect at a time.

Turning off the master analysis switch intentionally removes live Portrait,
Marks, and other feature-driven overlays. Person Key has a safe pass-through
fallback when its matte is unavailable, so image effects remain visible
instead of turning the frame transparent.

## Implementation notes

- `ProcessingQuality` now applies to the GPU graph, not only the legacy Core
  Image path. The compositor renders into a pooled working format and performs
  one final upscale into the output pool.
- `MetalEffects.applyChain` batches all enabled kernels and their final copy in
  one command buffer per chain. The previous per-kernel commit/wait/flush loop
  is retained only for isolated callers.
- Empty effect chains avoid both the copy kernel and the compositor's extra
  full-frame clear before rasterizing a layer.
- Analysis gating happens before segmentation and landmark requests, so the
  filter-only path does not merely hide the overlay after paying its cost.
- Session persistence now coalesces rapid settings changes for 0.4 seconds.
  Canvas pan/zoom no longer JSON-encodes and writes the entire session for
  every intermediate position. Processing settings still update immediately.

## Verification

The optimization commit was verified with:

```sh
xcodegen generate
xcodebuild -project SketchCam.xcodeproj -scheme SketchCam \
  -configuration Debug -sdk macosx test CODE_SIGNING_ALLOWED=NO
```

That historical run passed all 141 tests (95 core, 46 app) and the unsigned
macOS build succeeded. The expanded suite passed 156/156 on 2026-09-26 with
`-parallel-testing-enabled NO`; a parallel run had three macOS test-host
crashes, while those tests passed serially. No live-camera FPS improvement has
yet been measured for the session-persistence change.

The next performance check should be a manual camera run with the Performance
panel visible. Report the before/after FPS, Process, and Frame total with the
same output format and effect stack; do not infer live-camera FPS from the
headless processor throughput tests.
