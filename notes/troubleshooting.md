# Troubleshooting

## `No Account for Team "K39T7B8529"`

Open Xcode, go to Settings, add the Apple Developer account, and retry the signed build with `-allowProvisioningUpdates`.

## `No profiles for io.github.languel.sketchcam`

Automatic signing needs to create Mac App Development profiles for the app and extension. Use Xcode once if CLI provisioning cannot create them.

If Xcode reports that the Mac is not registered, run the local build once with device registration enabled:

```sh
SKETCHCAM_ALLOW_DEVICE_REGISTRATION=1 ./script/build_and_run.sh
```

## Activate Fails Immediately

Make sure you are running `/Applications/SketchCam.app`, not a build product inside DerivedData. System extensions must be activated from an app in `/Applications`.

Also make sure LaunchServices is not resolving the bundle ID to a build product. The local run script unregisters its build product after copying the app, but you can inspect the current registrations with:

```sh
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -dump | rg -A12 -B3 'io\.github\.languel\.sketchcam|SketchCam\.app'
```

## `Extension not found in App bundle`

Resolved 2026-06-10 — three concrete causes were found, in order of likelihood:

1. **Extension bundle name must equal its bundle identifier.** sysextd only
   matches `Contents/Library/SystemExtensions/<bundle-id>.systemextension`.
   The bundle is now named
   `io.github.languel.sketchcam.camera-extension.systemextension`
   (set via `PRODUCT_NAME` in `project.yml` — do not rename it back).
2. **Extension Info.plist missing `CFBundleVersion`/`CFBundleShortVersionString`**
   (e.g. from a stray global `GENERATE_INFOPLIST_FILE=YES`) makes the
   SystemExtensions framework skip the bundle entirely.
3. **Stale LaunchServices registrations** of build-directory copies make
   sysextd resolve the bundle id to a copy outside `/Applications`
   (`sysextd: no policy, cannot allow apps outside /Applications`).
   `script/install_release.sh` cleans these automatically.

Check the loader log:

```sh
/usr/bin/log show --style compact --last 5m --predicate 'process == "sysextd"' | rg -i 'sketchcam|languel|policy|outside /Applications|activation request'
```

Activation under normal policy (SIP on, no developer mode) requires the
notarized Developer ID build from `script/release_build.sh` — an Apple
Development build cannot activate outside developer mode. See
`notes/notarization.md` for the full distribution pipeline.

## Extension Approval Does Not Appear

Open System Settings and check:

```text
General -> Login Items & Extensions -> Camera Extensions
```

Also check:

```sh
systemextensionsctl list
```

## Camera Client Shows Fallback Pattern

The extension is active, but SketchCam.app is not publishing fresh host frames in the active format.

Check:

- Camera permission in System Settings.
- Test pattern toggle in SketchCam.
- Output preset in SketchCam.
- Whether another app is already holding exclusive camera access.

## Remove The Extension

Deactivate from SketchCam, then remove `/Applications/SketchCam.app`. macOS should also remove the bundled system extension. If it remains pending, reboot and check `systemextensionsctl list` again.

## Virtual camera shows striped test pattern instead of the processed feed

The stripes are the extension's fallback, generated whenever no sink frame
arrived in the last second. Two causes found (2026-06-10):

1. `CMIOStreamCopyBufferQueue` returns **noErr with a NULL queue** when the
   queue-altered callback is nil. The publisher must pass a (no-op) proc —
   fixed in `SketchCam/VirtualCamera/VirtualCameraFramePublisher.swift`
   (symptom: Debug panel shows `Virtual: Failed: queue 0`).
2. If the SketchCam app was already running when the extension was activated,
   its CMIO device list is stale and the sink is never found (symptom:
   `Virtual: SketchCam sink not found`). Restart the app after activating the
   extension.

Healthy state: Debug panel shows `Virtual: Publishing`, and consumers
(Photo Booth/QuickTime) show the processed feed.
