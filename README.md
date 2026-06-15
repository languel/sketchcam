# SketchCam

SketchCam is an open programmable virtual camera host for interactive art teaching, live performance, and local computer-vision experiments.

A macOS app captures a webcam, runs a GPU compositing pipeline, previews it, and publishes the result as a Core Media I/O virtual camera named **SketchCam** that any camera consumer (QuickTime, Zoom, OBS, TouchDesigner, browsers) can select.

## Features

- **Sources**: any camera, or a looping movie file / http(s) stream with 0–2x playback speed (0 = pause) for deterministic testing; freeze-frame on any source (⌘F); export the current published frame as PNG with alpha (⌘E).
- **Effects**: black-and-white threshold (with "ink only" transparent-paper mode and invert) and solid-color outline strokes (edge sensitivity, thickness 0–24 px, stroke color + opacity), individually bypassable.
- **Layers**: live input layer toggle; background = live video, solid color (color + opacity picker), or true alpha; the published BGRA frames carry a real alpha channel for downstream compositing (TouchDesigner etc.).
- **Person keying**: Vision person segmentation (fast/balanced/accurate) masks the layer stack to the person — Cutout or flat-color Silhouette mode, invertible (the outline always stays on the subject).
- **Marks** (raw landmark data): Apple Vision backend (synthetic source for tuning), tracked as fine-grained regions — face split into Jaw / Nose / Mouth / L+R Brow / L+R Eye, body into Head / Torso / L+R Arm / L+R Leg, plus Hands and a silhouette Contour — each independently toggleable with its own color + size. Rendered as dots and/or a MediaPipe-style stick figure (eye shapes, articulated fingers, body skeleton); stable IDs with adjustable color-matched labels (hands use MediaPipe 0–20 indices), detection rate 1–15 Hz. Jitter-stable: canonical joint ordering, chirality-locked hands, identity-keyed smoothing with dropout carry-over. The **Contour** follows the silhouette boundary (Moore tracing) with an adjustable Detail (granularity) so it hugs concavities.
- **Drawing** (art from the landmark data): modular algorithms that each toggle independently and **layer** on the canvas, each with its **own** color palette, "match landmark colors" option, and seed. Deterministic from the seed, so shapes stay stable under motion.
  - **Yarn** — seeded woven tangle per feature; Weave (waviness), coil/loop Noise (linear × circular) and Winding.
  - **Wrap** — a continuous yarn-wire that winds through the *inside* of the person (Gormley-style): heavy interior sampling, proximity-ordered, with LineWalk-style Wildness/Scale and coil/winding Loops.
  - **Line walk** — "taking a line for a walk": one or more continuous lines planned through the semantic features. Continuity (one unicursal line → separate paths → fragments), Density, a Curve picker (Polyline / Spline / Hobby / Bezier), a 2-D Wildness pad (along-path × orthogonal), Scale (local↔global).
  - All algorithms render as smooth variable-width **ribbons** (calligraphic taper/swell) with an optional glow **Halo**; an optional **GPU (Metal)** path tessellates every enabled algorithm in one pass.
- **Ink**: a full-canvas shader inkwash layer with editable vector paths, paper grain, Beer-Lambert ink density, wet diffusion, fix/clear commands, black/white ink, pen/wash modes, and an Excalidraw-style mini editor. Shortcuts include `P`/`7` draw, `V`/`1` select, `A` points, `B` pen/wash, `W` black/white, `D` fix, `C` clear, Delete, undo/redo, save, fullscreen, and right-drag wash.
- **Presets**: save the entire app state (effects, threshold, background + the full drawing/detection config) as named, persistent presets; recall either just the render style (Marks/Drawing/Detection) or the whole state.
- **UI**: tabbed controls (Settings / Layers / Effect / Marks / Yarn / Wrap / Line walk / Ink / Web / Presets / Keys / Debug) with compact one-line style rows (color + size per visual element).
- **Performance controls**: input resolution (352/VGA/720p/native), processing resolution decoupled from output (full/720p/540p), output format, preview on/off, GPU drawing + stroke style toggles (Settings ▸ Rendering), per-stage ms HUD.
- The pipeline sustains 30 fps at 1080p with all features enabled (~2–5 ms/frame on the hot path; detection and segmentation run off-path on their own queues). See `notes/performance-plan.md` for the audit, architecture, and measured numbers.

## Current Status

- Target platform: current macOS 26.x first.
- Local toolchain tested here: macOS 26.5.1, Xcode 26.5.
- Project source of truth: `project.yml` via XcodeGen.
- License: MIT.

Older macOS versions are not promised yet.

## Build

Install XcodeGen once:

```sh
brew install xcodegen
```

Generate the Xcode project:

```sh
xcodegen generate
```

Build and run tests without signing:

```sh
xcodebuild \
  -project SketchCam.xcodeproj \
  -scheme SketchCam \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Run Locally

Use the project script:

```sh
./script/build_and_run.sh
```

The script regenerates the Xcode project, builds `SketchCam.app`, copies it to `/Applications/SketchCam.app`, and opens it. The `/Applications` location matters because macOS system extensions must be activated from an app bundle in `/Applications`.

On a first run on a new Mac, allow Xcode to register the device while creating the development profiles:

```sh
SKETCHCAM_ALLOW_DEVICE_REGISTRATION=1 ./script/build_and_run.sh
```

## Release Build (Developer ID, Notarized)

On SIP-enabled macOS, the system extension only activates from a notarized Developer ID build. The working pipeline (see `notes/notarization.md` for the full story):

```sh
./script/release_build.sh        # archive + developer-id export → build/Release-export/SketchCam.app
./script/notarize.sh             # notarytool submit + staple (keychain profile, see notes)
./script/install_release.sh     # copy to /Applications + LaunchServices cleanup
./script/verify_signing.sh      # signatures, entitlements, spctl, systemextensionsctl report
```

Then launch the app, click **Activate**, approve in System Settings → General → Login Items & Extensions → Camera Extensions, and **restart the app** so it picks up the new CMIO device.

## Signing And Activation

Camera Extension development builds require Apple Development signing and provisioning profiles with the app group and system-extension capabilities. On SIP-enabled macOS 26, development-signed builds cannot activate the extension under normal policy — use the Release pipeline above (or system-extension developer mode from Recovery).

The project is configured for:

- App bundle ID: `io.github.languel.sketchcam`
- Camera extension bundle ID: `io.github.languel.sketchcam.camera-extension`
- App group: `$(TeamIdentifierPrefix)io.github.languel.sketchcam`
- Team: `K39T7B8529`

If CLI signing reports `No Account for Team "K39T7B8529"`, open Xcode, add the Apple Developer account in Settings, then let automatic signing create/update the profiles.

If activation fails with `Extension not found in App bundle`, check `notes/troubleshooting.md` — the known causes are the extension bundle not being named after its bundle identifier, missing version keys in its Info.plist, or stale LaunchServices registrations.

To activate the virtual camera:

1. Run SketchCam from `/Applications/SketchCam.app`.
2. Click **Activate** in the Camera Extension section.
3. Open System Settings when prompted and approve the extension.
4. Check activation:

```sh
systemextensionsctl list
```

## Test Clients

Required Phase 1 manual checks:

- QuickTime Player: New Movie Recording, camera menu, select SketchCam.
- FaceTime: video menu/camera picker, select SketchCam.
- Chrome: open a site with camera permissions, select SketchCam in site/browser camera settings.

Best-effort checks:

- OBS
- Zoom

If no host frames are arriving, the extension should keep outputting its generated fallback pattern instead of freezing.

## Development Notes

- App-side product logic lives in `SketchCam` and `SketchCamCore`.
- The camera extension stays thin: it consumes app-provided frames on a CMIO sink stream, republishes them on a CMIO source stream, and generates fallback frames.
- The default output preset is 1920x1080 at 30 FPS; 1280x720 and 640x360 are also exposed.
- Core Image is the first processor backend; the `FrameProcessor` boundary allows Metal or other renderers. The Drawing overlay already has a Metal path (`StrokeTessellator` → `MetalLineRenderer`, tessellated ribbons into an IOSurface) opt-in via Settings ▸ Rendering ▸ GPU drawing. The Ink layer is generated by a separate Metal feedback engine and handed back to the compositor as a materialized image, avoiding persistent Core Image feedback graphs.

See `notes/architecture.md`, `notes/phase-1-test-plan.md`, and `notes/troubleshooting.md` for more detail.
