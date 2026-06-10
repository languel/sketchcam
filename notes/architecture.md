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

## Future Boundaries

The stable long-term shape is:

```text
frame input -> processing/runtime -> semantic state -> rendered frame -> platform outputs
```

Phase 2 can add inference, OSC/WebSocket state output, zones, and sketch hosting without moving virtual-camera mechanics into the product layer.

