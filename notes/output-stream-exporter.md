# Output Stream Exporter

SketchCam treats export as another consumer of the fully composited frame. The
live pipeline continues publishing the virtual camera at its configured size;
`OutputStreamExporter` copies only accepted frames, reframes them at the export
size, and sends them to a dedicated writer queue.

```text
compositor -> publish(frame)
                |-> virtual camera
                |-> preview
                `-> OutputStreamExporter (inactive: one lock + branch)
                       |-> ImageIO still / sequence / GIF
                       `-> AVAssetWriter movie
```

## Three clocks

- **Capture FPS** decides when a source state is sampled.
- **Playback FPS** assigns presentation timestamps to accepted frames.
- **Simulation FPS** advances the isolated NRT ink renderer.

They are deliberately independent. Capturing one frame every three seconds at
30 playback FPS produces stop-motion compression; capture above the live render
rate duplicates the most recent completed frame and reports it. NRT capture
above simulation rate repeats unchanged simulation states unless simulation FPS
is raised.

## Capture rules

Version 2 uses one trigger and zero or more AND gates. Mouse and gesture events
arm a pending capture which is fulfilled by the next fully composed frame, so an
event never saves the stale frame from before the action. Gates can inspect
mouse/Draw/Wash state, solver activity, physical ink change, final output, a
stable UUID-addressed layer's post-effect output, or a GPU control field
(paper absorbency or motion magnitude). Metrics are mean luma,
threshold coverage, alpha coverage, and inter-frame change/motion.

The post-effect layer/control-field taps are dormant unless an active session
addresses them. Metric images are reduced on the GPU and only one pixel per
metric is read back; no full export frame crosses to the CPU for analysis.

## Writers and destinations

- Still/sequence: PNG, TIFF, JPEG, HEIF through ImageIO.
- Movie: H.264/HEVC in MOV or MP4; ProRes 422, 422 HQ, and 4444 in MOV.
- GIF: ImageIO animation with the expected indexed-palette, transparency, and
  frame-delay precision limits.

Every destination has an explicit **Create new take** or **Replace** collision
policy. Image sequences create a take directory and never mix frames into an
existing non-empty take. Optional sidecars record timing,
trigger, duplicate/drop state, and output indices. Optional poster frames are
written beside the primary output.

## Performance and NRT

Canvas undo state remains mutable, while `PerformanceEventLog` is append-only.
Gesture events keep monotonic start/end times, per-sample path timing, material
settings, stable action IDs, and explicit undo/redo/command events.

NRT replay snapshots the current settings, source frame, and event log, creates
an independent ink compositor, control-field graph, and frame processor, then
advances a synthetic clock. Recorded sample times reveal each gesture across
its real duration rather than popping in a completed path. Replay supports
original timing, removed idle gaps, fixed gaps, a global speed multiplier, and
material snapshots. Undo/redo and canvas commands remain explicit events.

NRT Continue clones the exact GPU pigment, fixed pigment, wetness, velocity,
pressure, and lock fields into an isolated engine. Both engines can then advance
at a fixed simulation step without the export mutating the live canvas. The
physical clone stays at its native simulation resolution and is framed to the
requested output size by the exporter.

Camera and Web inputs freeze their latest completed frame by default. For
moving deterministic input, **Record input proxy** creates temporary HEVC Camera
and Web tracks. NRT addresses those tracks by frame time; Source start/end and
looping define the range. Proxy files are deleted on normal quit and stale
session folders are pruned on the next launch.

## Performance guarantees

No encoding or metric reduction occurs while export is inactive. Live cadence
captures use a bounded four-frame writer queue; overload is counted instead of
growing memory without limit. Manual and event captures are retained. NRT uses
back-pressure on that same queue. Writer and disk-limit failures stop the
session and ask native writers to finalize what they can.
