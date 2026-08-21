# SketchCam Phase 1 Architecture

## Pipeline

SketchCam.app owns the product pipeline:

```text
AVFoundation camera input
  -> CVPixelBuffer
  -> CoreImageFrameProcessor
  -> processed CVPixelBuffer + CMSampleBuffer
  -> SwiftUI preview
  -> CoreMediaIO sink stream
  -> SketchCamCameraExtension
  -> CoreMediaIO source stream
  -> camera clients
```

The extension is an output adapter. It does not capture the webcam and does not contain product effects.

## Per-Layer Camera Effects

The GPU compositor applies each layer's ordered `EffectConfig` chain before
masking and compositing. In addition to Threshold, Outline, Levels, Blur, and
the analytical effects, the chain includes deterministic print-like passes:

**Levels / Gain** is a separate chain effect that can be placed immediately
before Blue-noise Stipple. It remaps black/white points, applies gamma and
midpoint gain, then blends a configurable smooth shoulder into the extremes;
this gives stipple density a continuous tonal ramp without the hard contour of
Threshold.

**Duotone / Tint** is a separate continuous two-colour remap. Its Shadow and
Highlight colours, blend amount, black/white points, gamma, and inversion are
all persisted, so it can be used before a print pass or as a finished tint.

- **Blue-noise Stipple** is the independent comparison pass. It builds a
  jittered candidate field, assigns each candidate a stable rank, rejects it
  when a lower-ranked neighbour is inside the Poisson radius, and then reveals
  a progressive subset from the source tone. A gamma-shaped luminance response
  keeps highlights sparse, while a multi-direction local gradient gives eyes,
  mouths, edges, and other detail a higher sampling priority. This is a GPU
  adaptation of the progressive blue-noise ideas in Jose Esteve's
  [Stippling and Blue Noise](https://www.joesfer.com/?p=108) reference and its
  [LGPL source repository](https://github.com/joesfer/Stippling); it is kept as
  a separate effect so it can be compared directly with the original Stipple.
- **Stipple** retains the earlier deterministic progressive Poisson-like
  particle field and its feature-pull behaviour.
- **Stripes** rotates a stripe field and samples along each stripe so short ink strokes change width with luminance/features, following the [portrait-in-stripes idea](https://liipetti.net/erratic/2015/10/20/a-portrait-in-stripes/) of repeated strokes whose thickness tracks source brightness. A separate variation scale controls the spatial wavelength of those width changes; Response controls the range of the tonal width mapping, and Bleed adds explicit headroom for neighbouring stripes to merge.
- **Pixel dots** samples one source cell per mark and can transition from square pixels to round dots.

Each pass exposes density/blend, cell scale, mark width, softness, sampling,
variation scale (stripes), angle (stripes), dot response (stipple), tone invert,
and foreground/paper tint controls. Dot response interpolates between constant
mark size and a radius proportional to sampled luminance/local feature energy.
Stripe response does the equivalent for stroke width: 0 is nearly uniform,
1 is the baseline tonal mapping, and larger typed values exaggerate the range.
Stripe bleed controls whether widths can exceed one stripe period, so adjacent
strokes can meet or overlap instead of being hard-separated.
The scale-to-cell mapping has a gentle knee above roughly 12 px: fine fields
remain easy to tune while coarse fields get additional usable headroom. Slider
ranges are UI defaults, not hard limits; typed numeric values are retained and
reach the GPU until the particular effect saturates visually.
Paper is
transparent by default, so only the source-derived marks composite over the
layers below; disabling transparency enables a tinted paper field. Pattern
parameters are persisted in the layer graph, and the kernels use no frame-time
randomness, so live video remains stable instead of shimmering. They are
GPU-compositor effects; disabling the
GPU compositor falls back to the legacy Core Image path, which currently does
not render user-authored per-layer effect chains.

User-created Solid layers expose the same RGBA colour picker in the layer row
and the expanded node inspector, including opacity. The graph stores that colour
on `SolidConfig`, independent of the layer's blend and opacity controls.

The reference implementation is discussed in [Stippling and Blue Noise](https://www.joesfer.com/?p=108)
and its [LGPL-3.0 source repository](https://github.com/joesfer/Stippling). SketchCam uses an
independent GPU adaptation rather than copying the C# implementation: the full
sequential dart-throwing/AIS pass is not suitable for every live video frame,
so the progressive rank and local Poisson-distance ideas are evaluated in the
Metal kernel.

## Session Restore And Permissions

The app writes a versioned `SketchCamSessionSnapshot` to `UserDefaults` as live
pipeline choices change. `ProcessingSettings` remains the canonical serialized
layer/effect/workspace state; the snapshot adds source selection, camera device
ID, input/output formats, movie rate, and security-scoped bookmarks for local
movie/Web inputs. Panel layout, window mode, and the secondary output window
keep their own small `UserDefaults` records.

Camera permission is deliberately not persisted. On start and app activation,
SketchCam re-queries AVFoundation, refreshes devices, reconnects the remembered
device when present, and requests access when the status is undecided. A denied
or restricted camera falls back to the test pattern and exposes Settings and
Refresh actions in the Camera panel. System-pointer arming remains transient
and explicit for safety.

## Targets

- `SketchCam`: SwiftUI utility app, camera picker, controls, preview, extension activation, frame publishing.
- `SketchCamCore`: app-side state, processing settings, Core Image threshold processor, test pattern generation.
- `SketchCamShared`: frame presets and pixel/sample-buffer helpers used by app, core, tests, and extension.
- `SketchCamCameraExtension`: Core Media I/O provider, source stream, sink stream, latest-frame store, fallback frames.

## Core Media I/O Streams

The extension exposes two streams on one virtual device named `SketchCam`:

- Source stream: camera clients read frames from this stream.
- Sink stream: SketchCam.app writes processed frames into this stream.

The extension stores the latest matching host-provided sample buffer. If no fresh host frame is available for the active format, it sends a generated fallback pattern.

## Formats

Phase 1 advertises three 30 FPS BGRA presets:

- 640x360
- 1280x720
- 1920x1080, default

Input frames are aspect-filled into the selected output format. Mirror is on by default.

## Drawing And Ink Layers

Landmark-driven drawing can render through the CPU path or through the Metal ribbon renderer:

```text
semantic paths -> StrokeTessellator -> MetalLineRenderer -> IOSurface-backed overlay
```

Yarn, Wrap, and Line Walk derive routes procedurally from the enabled landmark
groups. Portrait instead keeps a semantic ordering across face and body
features. Incoming landmark motion deforms that existing route, so animation
morphs continuously instead of changing topology as nearest-neighbour choices
shift. Its Fluid, Cubist, and Ornate styles deform the route before the same
shared ribbon tessellation stage. Portrait splits groups by structural edges,
then visits face features in a seeded semantic itinerary and body features in
head → left arm/hand → torso → right arm/hand → legs order. Hand detector labels
are retained through the canvas mapper so left/right anatomy remains stable
under mirrored output. Portrait's seed drives deterministic route sampling,
open-chain reversals, closed-feature starts, bridges, drift, and flourishes;
the choice remains fixed while landmarks move. An optional face-only Clean/Wild
crown component joins that same seeded face itinerary. The configurable
segment count can split the itinerary only at semantic boundaries, while
cross-region bridges render thinner than same-region links. The separate
contour/hull route remains a body silhouette.

When GPU drawing is enabled, ribbons remain on the Metal path even if raw Dots,
Stick, or IDs are visible. Marks render into their cached CGContext layer and
the Metal art layer composites above it, preserving the established order while
avoiding CPU fills for long self-crossing portrait routes. Predictive redraws
reuse a geometrically growing Metal vertex buffer; Portrait also ignores dense
Contour/Hull fallback geometry when an articulated body route is already
available and caps pathological route inputs without changing normal portraits.

The Ink tab is a separate full-canvas drawing layer. It stores editable vector paths in `ProcessingSettings`, then replays them through a native Metal feedback simulation:

```text
InkEditorPath log
  -> MetalInkEngine
  -> RGBA16F mobile ink + RGBA16F fixed ink + R16F wetness
  -> RG16F velocity + R16F pressure/divergence/curl
  -> BGRA materialized layer
  -> CoreImageFrameProcessor composite
```

The inkwash layer deliberately keeps feedback state inside Metal textures. The Core Image processor receives only the latest flat BGRA layer, which avoids building a persistent recursive CI graph while preserving the existing layer ordering with the other drawing/web overlays.

The editor uses normalized top-left canvas coordinates. Metal replay uses the same coordinate system so the vector guide path and the simulated shader stroke stay aligned on the preview.

## Program And Presentation Destinations

Workspace visibility has two independent destination filters:

- `includeInOutput` controls the normal program/virtual-camera composite.
- `includeInPresentation` controls the secondary Output window when its source
  is **Presentation**.

Both destinations use the same layer graph, streams, transforms, crop, masks,
effects, and output viewport. Only frame participation differs. Presentation is
rendered on demand while that Output-window source is active; otherwise the
secondary display reuses the normal program frame. Old workspace documents copy
their program inclusion value into presentation inclusion when decoded, which
preserves their previous appearance.

## Path And System-Event Routing

The current Drawing producer has one typed `analysis` path input. Its runtime
resolver preserves Landmarks as the default and can instead adapt the shared
Mouse/canvas stroke log into `LandmarkDetection`: each authored stroke remains a
separate connected group, and top-left canvas Y is flipped into Vision's
bottom-left normalized coordinates. The active stroke snapshot is non-consuming,
so routing it to Drawing does not starve the Ink engine.

Input Map is the first route in the opposite direction—from analyzed camera
features to an external event sink:

```text
camera frame
  -> independent Vision hand tracker
  -> semantic MediaPipe-style feature (L0...L20 / R0...R20)
  -> pointer mapping + smoothing + pinch hysteresis
  -> CGEvent mouse move/down/drag/up
  -> macOS session
```

The pure mapping engine owns coordinate conversion and button lifecycle. A narrow
AppKit/ApplicationServices controller owns Accessibility trust and Quartz event
posting. SwiftUI owns the Codable mapping editor. The independent hand-only
tracker prevents arming Input Map from changing the Marks/Drawing detector's
source or enabled regions. See `notes/input-mapping.md` for current behavior,
safety rules, and limitations.

Immediate ink is also represented by a private timestamped action log even
when it is not exposed as an editable path. A bounded GPU checkpoint ring stores
the complete physical simulation at action boundaries, allowing exact undo and
redo without cumulatively reapplying fluid forces. The ring depth is a user
preference, reports its estimated unified-memory use, and is hard-capped at half
of physical RAM. Semantic actions remain authoritative when a checkpoint has
aged out.

Future process-timelapse capture and disk-backed undo should share these action
boundaries. A timelapse image is presentation output only; restoring a canvas
requires the corresponding pigment, wetness, velocity, and lock fields.

## Future Boundaries

The stable long-term shape is:

```text
frame input -> processing/runtime -> semantic state -> rendered frame -> platform outputs
```

Future routing can generalize the single Input Map into multiple feature → event
bindings and add OSC/WebSocket, multitouch, zones, path-output nodes, and sketch
hosting without moving virtual-camera mechanics into the product layer.
