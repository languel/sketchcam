# Performance: incremental plan + overhaul plan (2026-06-13)

## ★ DECISIONS / NEXT-SESSION START HERE (2026-06-13)

User direction after the leak fix landed:

- **Go full GPU / Metal.** No compatibility concerns — **drop Intel Macs**,
  Apple-silicon only (target is M-series, e.g. M5 Max / 128-core GPU). Priority
  is raw performance; the user expects far more from the hardware than we deliver.
- **Effects are optional — OK to drop entirely.** **Detection and drawing are
  paramount.** The goal: beautiful, interactive, expressive *parametric drawings
  from feature extraction* (LineWalk family). Optimize for that, not the
  CoreImage effect chain.
- **Make more things toggleable** (e.g. preview on/off, per-stage bypass) so the
  user can trade cost for fidelity live.
- Still feels **sluggish even after the leak fix** → confirmed by the HUD:

  | Stage | Live (busy) | Frozen |
  |---|---|---|
  | **Overlay** | **54.0 ms** | 14.8 ms |
  | Detect | 15.7 ms | 15.1 ms |
  | Segment | 5.5 ms | 6.9 ms |
  | Process | 1.7 ms | 1.8 ms |
  | Frame total (hot path) | 2.3 ms | 2.8 ms |

  The **Overlay (drawing) render is the bottleneck at ~54 ms** — it runs async
  off the hot path, but at >33 ms it can't keep up with 30 fps detections, so the
  drawing visibly lags. This is the CPU `CGContext` vector render:
  `strokeVariableWidth` issuing one `strokePath` per sub-segment + LineWalk
  sampling/perturbation at high density. **This is the #1 thing to move to GPU.**

→ **Plan: go straight to Plan B (Metal overhaul) on a new branch**, prioritizing
  the **drawing/overlay pipeline on the GPU** (tessellate LineWalk strokes to
  triangle ribbons, render in Metal, composite to an IOSurface-backed buffer),
  plus a **zero-readback preview** (MTKView / AVSampleBufferDisplayLayer). Keep
  Vision detection/segmentation native and the LineWalk geometry (Core, pure).
  Effects can be dropped or reduced to a couple of Metal shaders. Do a couple of
  cheap Plan A wins first only if trivial (toggleable preview; batch the stroke
  render) — but the real target is GPU drawing.

  Detection at 15 ms is the next ceiling after drawing — revisit cadence /
  downsample size, but detection + drawing quality are the product, so tune
  rather than cut.

---


Audit method: live `sample`+`vmmap` of the running app, then a 14-agent
read-only audit (7 subsystem analyses → 3 adversarial leak lenses → 3 overhaul
options → synthesis). Findings below are filtered through independent
code-reading + the live evidence, NOT taken verbatim from the agents (who
over-anchored on one hypothesis — see "Root cause" below).

## Root cause of the catastrophic failure (FIXED)

The beachball + 134 GB footprint was a **single bug**: `VirtualCameraFramePublisher`
enqueued each frame's `CMSampleBuffer` with `Unmanaged.passRetained` (+1) but, when
evicting stale frames from a full CMIO sink queue, discarded the
`CMSimpleQueueDequeue` result **without releasing** that retain. Every evicted
frame leaked its 1080p IOSurface forever.

- Proof: 16,682 leaked IOSurfaces of **uniform** ~7.9 MB (= 1920×1080 BGRA).
  Only the published-frame path is 1080p; a leak elsewhere (CIImage temps,
  Vision results, downsample buffers) would be heterogeneous sizes.
- 2 of 3 adversarial lenses independently named this the primary cause; the
  synthesis agent mis-ranked "missing autoreleasepool" #1.
- **Fixed** (commit `a42b8c9`): release on evict + drain on disconnect.
  Verified: footprint flat at ~370 MB RSS / ~142 MB IOSurface over 3 min
  (was climbing tens of GB/min). ~360× reduction.

**Lesson / rule:** any `Unmanaged.passRetained` MUST have a matched release on
every exit path (evict, disconnect, error). Audit other `Unmanaged`/`passRetained`
/ `CMSimpleQueue` / manual-CF-retain sites for the same imbalance.

---

## Plan A — Incremental optimization (current native engine)

Goal: stable, leak-free, comfortable 30 fps 1080p with headroom, keeping the
AVFoundation + CoreImage + Vision + CMIO architecture. Ordered, measurement-gated.

1. **[DONE] Publisher leak fix** — committed + verified.
2. **Long-run memory soak (30–60 min)** before adding anything else. Much of the
   old 8.5 GB `MALLOC_SMALL` was almost certainly the per-sample-buffer metadata
   of the 16,682 leaked buffers and is likely already gone. Confirm footprint is
   truly flat over a long run.
3. **`autoreleasepool` wraps — only if (2) shows residual growth.** The audit
   ranked these #1; the evidence says they were NOT the 125 GB cause (modern GCD
   already drains a pool per `.async` work item). They are cheap, zero-risk
   hygiene worth adding regardless, but they are *hygiene, not the fix*. Sites:
   `SketchCamViewModel.process` (processingQueue), `LandmarkDetectionService`,
   `SegmentationService`, `LandmarkOverlayCompositor.renderAsync`.
4. **`CIContext(cacheIntermediates: true)` → default `[:]`** at the three sites
   (`SketchCamViewModel:78`, `CoreImageFrameProcessor:18`, `PreviewRenderer:16`).
   Every frame is unique, so cross-frame intermediate caching only pins Metal
   textures. Low risk; measure GPU memory before/after.
5. **Compute hotspots (profile-driven, after memory is confirmed stable):**
   - **`DrawingSupport.strokeVariableWidth`** issues one `CGContext.strokePath`
     per sub-segment → potentially hundreds–thousands of stroke calls per overlay
     render at high Density/Detail. Biggest CPU-overlay win: build a single
     variable-width ribbon path (triangle strip / filled outline) and stroke/fill
     once, or batch segments. (medium effort, high impact)
   - **Contour Moore-trace + resample** at high Detail (≤240 pts) over the matte —
     bounded and off-hot-path (utility queue, rate-limited), so lower priority;
     cap Detail or simplify (Douglas–Peucker) if it shows up.
   - **LineWalk `tour`/`partition`** are O(n²) but n≈feature-count (~15); trivial
     today. Only matters if multi-person / very high density lands. (low priority)
   - **`CIMorphologyMaximum`** (outline dilation) at full res — run the effect
     chain at the existing decoupled processing resolution (540/720p) and upscale.
   - Detection cost is dominated by the 3 Vision requests themselves, NOT by our
     15-region partitioning (the partition is O(joints), cheap) — the audit
     overstated "15-region overhead."
6. **Preview main-thread cost** (`CA::commit → IOSurfaceCreate`): preview is
   already downscaled ≤960px. Real fix is zero-readback preview = overhaul
   Phase 1. Incremental stopgap: lower preview Hz / size if needed.
7. **`PixelBufferPool` min count 4 → 3** — negligible; skip unless soak shows it.

Expected outcome: leak-free, lower steady CPU, overlay render cheaper at high
settings. This is mostly small/medium, low-risk work.

---

## Plan B — Overhaul (separate branch, only if Plan A headroom is insufficient)

**Recommendation: HYBRID — keep native I/O + detection, move rendering to Metal.**
(The 3 overhaul agents converged here; it's the high-ceiling, contract-preserving
path.)

**Keep:** AVFoundation capture; CMIO virtual-camera publish + the system
extension; Vision detection/segmentation; `LineWalk` pure geometry (Core);
the layer/settings model and the whole art philosophy.

**Replace:**
- Camera `CVPixelBuffer` → `MTLTexture` zero-copy via `CVMetalTextureCache`.
- CoreImage effect chain (threshold/edges/dilate/blend) → Metal compute/fragment
  shaders.
- Overlay compositing → Metal; LineWalk stays CPU geometry but its strokes are
  tessellated to GPU vertex buffers (or rendered to a texture uploaded once per
  detection) instead of per-frame CGContext.
- GPU output → IOSurface-backed `CVPixelBuffer` for the CMIO sink (the existing
  publisher contract is unchanged).
- **Preview → zero-readback** `AVSampleBufferDisplayLayer` or `MTKView` (kills the
  per-frame `createCGImage` + the main-thread CA surface allocation).

**Phasing (each independently shippable, behind a feature flag):**
1. Zero-readback preview (biggest isolated main-thread win, low risk).
2. Metal effect chain with visual-diff regression tests vs the CoreImage output.
3. Metal overlay compositing + GPU stroke tessellation.

**Why Metal over WebGPU/compute here:** the user has had better results with
WebGPU/compute elsewhere, and that's valid — but this app's hard constraint is a
macOS **CMIO camera system extension**, which needs GPU output back in an
IOSurface-backed `CVPixelBuffer`. Metal gives that with zero-copy IOSurface
interop natively; a WebGPU/wgpu/Dawn backend adds an FFI + surface-readback
impedance mismatch (high risk) for no extra ceiling on this platform. Revisit
WebGPU only if the project later targets the browser/cross-platform.

---

## Open questions for the user (gate the decisions)

1. After the soak, is ~370 MB steady-state fine, or is there a tighter target?
   (If fine, Plan A alone may be enough and the overhaul can wait.)
2. Is a **zero-readback live preview** wanted? It's the single biggest
   main-thread win and the natural overhaul Phase 1.
3. Confirm **Metal** (native, zero-copy) over WebGPU given the camera-extension
   constraint — or is browser/cross-platform a real future requirement?
4. Is **multi-person** or **very high landmark density** on the roadmap? That's
   what would force LineWalk geometry onto the GPU.
5. **Intel Macs** in scope, or Apple-silicon only? (Affects how Metal-first we go
   vs keeping a CoreImage fallback.)
6. How aggressively to cut: are you open to **dropping / simplifying effects**
   (e.g. the CoreImage filter chain) in favor of a few Metal shaders, or must
   current visual output be preserved bit-for-bit?

---

# metal-engine branch — session progress (2026-06-13)

## Shipped (branch `metal-engine`, pushed)
- **GPU stroke renderer** (`StrokeTessellator` in Core + `LineShaders.metal` +
  `MetalLineRenderer`): LineWalk strokes → triangles → 4× MSAA render into an
  IOSurface BGRA `CVPixelBuffer`. **Measured 5.56 ms/frame** for a busy
  1280×720 / ~1600-pt frame (synchronous + MSAA) vs **~54 ms** CPU CGContext —
  **~10×**, and the live async path should be cheaper. On-device self-check
  (DEBUG, writes container tmp/sketchcam-metal-selftest.txt) verifies pipeline,
  y-up orientation, premultiplied blend, IOSurface readback: PASS.
- **Opt-in wire-up**: Debug tab "GPU drawing (Metal)" toggle →
  `settings.landmarks.useMetalDrawing`. When on (and style = Line walk) the
  overlay is rendered on the GPU. Marks (dots/stick/labels) still CPU.
  ⚠️ Needs one visual check: confirm the Metal overlay isn't vertically flipped
  vs the CPU path (CIImage(cvPixelBuffer:) vs CIImage(cgImage:)). If flipped,
  it's a one-line shader change.
- **Preview choppiness FIXED**: preview was throttled to 12 fps (looked choppy
  vs the smooth live cam / 30 fps published stream). Raised to 30 fps.
- **Synthetic upside-down FIXED**: synthetic source was y-down; flipped to y-up.
- **App Nap disabled** while live (latency-critical ProcessInfo activity) — the
  practical "Game Mode" lever for a non-fullscreen app.

## Findings / diagnosis
- **Threshold "choppiness" was the preview throttle, NOT CoreImage.** CoreImage
  threshold/effects cost only ~1.7 ms/frame (HUD "Process"). So dropping
  CoreImage is a *strategic* full-GPU choice, not a perf emergency.
- **Overlay lag** ("drawing trails the body by fractions of a second") has three
  additive sources: (1) detection cadence (100 ms at 10 Hz — raise the Rate
  slider); (2) the tracker's one-pole smoothing (blend 0.45 trails motion);
  (3) overlay render time (54 ms CPU → 5.6 ms Metal). Metal drawing + higher
  detection rate shrink it; the structural fix is **landmark velocity
  extrapolation** (predict to the current frame time) — needs visual tuning.

## DECISION NEEDED (effects strategy)
User said effects are optional and they'd drop them for great drawings. Two paths:
- **(A) Drop effects → lean GPU pipeline**: camera → optional simple background
  (solid/alpha/live) → GPU LineWalk drawing → output. Smallest, fastest, all
  Metal. No CoreImage.
- **(B) Port effects to Metal**: reimplement threshold (incl. ink-only), outline
  (edges+dilation+colored strokes), person keying/masks, layers, invert as Metal
  shaders. Large, visual, but preserves current looks.
Recommend (A) first (it's the product per the user), add Metal effects later if
wanted. Either way: zero-readback MTKView/AVSampleBufferDisplayLayer preview.

## Next (when user is back to verify visually)
1. Flip on "GPU drawing (Metal)"; confirm orientation/quality; check Overlay ms.
2. Decide effects strategy (A vs B above).
3. Zero-readback preview.
4. Landmark extrapolation to kill the tracking lag.
5. Test clip: ~/Desktop/ref/chaplin-dance.gif was NOT present this session.
   Local movie files load via the movie file picker (openMoviePanel). If a clip
   is dropped in, convert to mp4 (ffmpeg available) and open it.
