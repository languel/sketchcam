# Phase 1 Test Plan

## Automated

Run:

```sh
xcodegen generate
xcodebuild -project SketchCam.xcodeproj -scheme SketchCam -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Expected:

- All unit tests pass.
- `SketchCam`, `SketchCamCore`, `SketchCamShared`, and `SketchCamCameraExtension` compile.
- Tests cover presets, default settings, test pattern generation, and processor output dimensions.

## Signed Local Build

Run:

```sh
xcodebuild -project SketchCam.xcodeproj -scheme SketchCam -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates build
```

Expected:

- Xcode can find an Apple Developer account for team `FAG3XX5RL8`.
- Automatic signing creates or updates profiles for the app and camera extension.

If this fails with account/profile errors, fix Xcode account/provisioning before testing extension activation.

## Manual Client Checks

1. Run `./script/build_and_run.sh`.
2. Click **Activate** in SketchCam.
3. Approve the extension in System Settings.
4. Confirm `systemextensionsctl list` includes `io.github.languel.sketchcam.camera-extension`.
5. Open QuickTime Player, FaceTime, and Chrome; select `SketchCam` as the camera.
6. Confirm the camera shows either the processed host feed or fallback pattern.
7. Toggle threshold, outline, invert, mirror, test pattern, and output preset.

Record results for OBS and Zoom when available.

