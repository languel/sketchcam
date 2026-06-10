# SketchCam

SketchCam is an open programmable virtual camera host for interactive art teaching, live performance, and local computer-vision experiments.

Phase 1 is intentionally narrow: a macOS app captures a webcam, renders a black-and-white threshold/outline effect, previews it, and publishes it as a Core Media I/O virtual camera named **SketchCam**.

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

## Signing And Activation

Camera Extension activation requires Apple Development signing and a provisioning profile with the app group and system-extension capabilities.

The project is configured for:

- App bundle ID: `io.github.languel.sketchcam`
- Camera extension bundle ID: `io.github.languel.sketchcam.camera-extension`
- App group: `$(TeamIdentifierPrefix)io.github.languel.sketchcam`
- Team: `FAG3XX5RL8`

If CLI signing reports `No Account for Team "FAG3XX5RL8"`, open Xcode, add the Apple Developer account in Settings, then let automatic signing create/update the profiles.

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
- Core Image is the first processor backend, but the `FrameProcessor` boundary is intended to allow Metal or other renderers later.

See `notes/architecture.md`, `notes/phase-1-test-plan.md`, and `notes/troubleshooting.md` for more detail.

