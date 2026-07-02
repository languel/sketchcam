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

Phase 2 can add inference, OSC/WebSocket state output, zones, and sketch hosting without moving virtual-camera mechanics into the product layer.
