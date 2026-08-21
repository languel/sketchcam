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

## Filter Stack Is Stuck Near 10 FPS

First separate image effects from analysis work. In the Input tab, leave **GPU
compositor (experimental)** enabled, set **Processing** to 720p or 540p, then
open **Analysis** and turn off **Live feature analysis**. This bypasses
MediaPipe/landmark and Vision person-matte requests while preserving the final
Output resolution. Turn off **Segmentation / person matte** too unless the
stack is intentionally testing Person Key or a matte-backed mask.

Use the Performance panel to compare **Process** and **Frame total** after each
change. Detect/Segment are last-run timings and can remain displayed briefly
after a bypass; they are not proof that a new analysis request is still on the
hot path. See [`notes/performance-plan.md`](performance-plan.md) for the
filter-only workflow and the current compositor details.

## Session state and camera recovery

SketchCam saves the live session as controls change. This includes the layer
graph and effect settings, selected output format, input resolution, camera
device ID, source choice, movie playback rate, and Output-window/window-mode
choices. A relaunch restores those values before the first frame is started.

Camera device IDs can change when a camera is unplugged or renamed. On launch
and whenever the app becomes active, SketchCam refreshes the device list and
selects the remembered device when it is available, otherwise the first
available camera. If macOS reports an undecided camera permission, the Camera
tab offers **Request access**; if permission was denied, use **Open Settings**,
enable SketchCam under Privacy & Security → Camera, return to the app, and
click **Refresh**. The remembered camera source is then started automatically.

If permission is unavailable, SketchCam keeps the session usable by falling
back to the test pattern until access is restored. The app does not silently
re-arm the system pointer; Input Map arming remains an explicit per-launch
safety action.

Local movie selections are stored with a security-scoped bookmark, so a picked
file can be reopened after relaunch without choosing it again. If the file was
moved or the bookmark is no longer valid, choose it again from **Movie → Open
Movie…**.

Local files used by the Web layer are restored the same way; remote `http(s)`
URLs do not need a sandbox bookmark.

## Input Map Will Not Arm After Accessibility Approval

Input Map requires the installed `/Applications/SketchCam.app` to be approved in
**System Settings → Privacy & Security → Accessibility**. Development rebuilds
must use the stable `/Applications/SketchCam.app` bundle and the same signed
designated requirement. The quick-run helpers intentionally never launch a
DerivedData copy.

One-time setup:

1. Build and install with `./script/build_and_run.sh`.
2. Add `/Applications/SketchCam.app` and enable it.
3. Return to SketchCam, click Refresh, and Arm. Input Map should say `Ready to arm`.

If a previous development certificate was used, macOS may retain a stale TCC
row. Remove that one row and add `/Applications/SketchCam.app` again. Future
source-only rebuilds should not require repeating this.

The scoped Terminal reset is an alternative to steps 2–3:

```sh
tccutil reset Accessibility io.github.languel.sketchcam
```

Then reopen SketchCam, click **Request access**, approve the installed app, and
click Refresh. `Request access` is now explicit; Arm no longer reopens System
Settings on every failed attempt.

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
