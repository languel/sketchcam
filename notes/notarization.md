# Signing, notarization, and system-extension distribution

Status: **working end-to-end as of 2026-06-10** — notarized Developer ID app,
camera extension `[activated enabled]`, virtual camera visible in Photo Booth.

## The issues we hit (in the order they were found)

1. **Release signed with Apple Development.** `project.yml` hardcoded
   `CODE_SIGN_IDENTITY: Apple Development` globally *and* in target `base`
   settings, so Release kept the development identity (and `get-task-allow`).
   In XcodeGen, target `base` settings override project config-level
   settings — never put signing identity/style in target `base`.
2. **Direct `codesign` with Developer ID is not enough.** A manually-signed
   build launches from Terminal but launchd/amfid refuse it
   (`RBSRequestErrorDomain Code=5`, POSIX 163; log shows
   `taskgated-helper: Disallowing … no eligible provisioning profiles found`).
   The `com.apple.developer.system-extension.install` entitlement **requires an
   embedded Developer ID provisioning profile at runtime** (OBS ships one too:
   `/Applications/OBS.app/Contents/embedded.provisionprofile`). Only the
   archive → `-exportArchive method=developer-id, signingStyle=automatic`
   path creates/embeds that profile (Xcode cloud signing,
   `-allowProvisioningUpdates`).
3. **Extension bundle name must equal its bundle identifier.** With
   `PRODUCT_NAME: SketchCamCameraExtension` the OSSystemExtension request
   failed with *"Extension not found in App bundle"*. sysextd only matches
   `Contents/Library/SystemExtensions/<bundle-identifier>.systemextension`
   (compare OBS: `com.obsproject.obs-studio.mac-camera-extension.systemextension`).
   Fixed by `PRODUCT_NAME: io.github.languel.sketchcam.camera-extension`.
4. **Extension Info.plist must keep CFBundleVersion/CFBundleShortVersionString.**
   A global `GENERATE_INFOPLIST_FILE=YES` override dropped them and produced
   the same "Extension not found" error. `GENERATE_INFOPLIST_FILE: YES` is now
   scoped to the two static-framework targets only (they need it to archive).
5. **Stale LaunchServices registrations.** sysextd resolves the app by bundle
   id via LaunchServices; leftover registrations of build-directory copies
   cause `sysextd: no policy, cannot allow apps outside /Applications`.
   `script/install_release.sh` now unregisters build copies and re-registers
   `/Applications/SketchCam.app`.
6. **Virtual camera showed the fallback stripes instead of the app feed.**
   `CMIOStreamCopyBufferQueue` returns noErr with a **NULL queue** when the
   queue-altered callback is nil, so every published frame was dropped
   (Debug panel: `Virtual: Failed: queue 0`). Fixed by passing a no-op
   callback in `SketchCam/VirtualCamera/VirtualCameraFramePublisher.swift`.
7. **App must be (re)launched after extension activation.** A running app has
   a stale CMIO device list and reports `Virtual: SketchCam sink not found`
   until restarted.

Healthy end state: app Debug panel shows `Virtual: Publishing`;
Photo Booth/QuickTime/FaceTime render the processed feed when "SketchCam"
is selected as camera.

## Correct identities

| Configuration | Identity | Style | Hardened runtime | get-task-allow |
|---|---|---|---|---|
| Debug | `Apple Development: liubomir borissov (FAG3XX5RL8)` | Automatic | NO | yes (injected by Xcode) |
| Release (exported) | `Developer ID Application: liubomir borissov (K39T7B8529)` | Automatic, applied at export | YES | **absent** |

Team ID for both targets: `K39T7B8529`. The archive itself is built with
development signing; `-exportArchive` re-signs everything with Developer ID,
strips `get-task-allow`, injects `com.apple.application-identifier`, and
embeds `Contents/embedded.provisionprofile`.

## App group format (investigated, intentional)

The entitlement `$(TeamIdentifierPrefix)io.github.languel.sketchcam` expands
to `K39T7B8529.io.github.languel.sketchcam`. This is the classic macOS
team-ID-prefixed app-group format and is correct for Developer ID
distribution (OBS uses the same scheme). Do not change it to `group.*`.

## Scripts

| Script | Purpose |
|---|---|
| `script/build_and_run.sh` | Debug build (Apple Development), install, run — unchanged dev loop |
| `script/release_build.sh` | archive → export → Developer ID app in `build/Release-export/SketchCam.app`, with regression checks |
| `script/notarize.sh [profile]` | Zip, submit via `notarytool`, staple, re-assess with spctl (default profile `sketchcam-notary`; `UPBGE_NOTARY` also works) |
| `script/install_release.sh` | Copy exported app to `/Applications` + LaunchServices cleanup |
| `script/verify_signing.sh` | Full report: signatures, entitlements, profiles, stapling, spctl, systemextensionsctl |

## Release + notarize + test, start to finish

```sh
script/release_build.sh
script/notarize.sh UPBGE_NOTARY    # or any notarytool keychain profile
script/install_release.sh
script/verify_signing.sh           # expect: accepted, source=Notarized Developer ID
open /Applications/SketchCam.app   # click Activate
# approve in System Settings > General > Login Items & Extensions > Camera Extensions
systemextensionsctl list           # expect: [activated enabled]
```

Notary credentials (one-time, app-specific password from account.apple.com):

```sh
xcrun notarytool store-credentials sketchcam-notary \
  --apple-id liuboto@gmail.com --team-id K39T7B8529
```

## Verifying signatures

```sh
APP="/Applications/SketchCam.app"
EXT="$APP/Contents/Library/SystemExtensions/io.github.languel.sketchcam.camera-extension.systemextension"

codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Runtime"
codesign -dv --verbose=4 "$EXT" 2>&1 | grep -E "Authority|TeamIdentifier|Runtime"
codesign -d --entitlements :- "$APP" | plutil -p -    # no get-task-allow for Release
spctl --assess --type execute --verbose "$APP"
```

Expected: `Authority=Developer ID Application: liubomir borissov (K39T7B8529)`,
`TeamIdentifier=K39T7B8529`, a `Runtime Version`, and
`accepted, source=Notarized Developer ID`.

## Regression guards

- `script/release_build.sh` fails if: either bundle isn't Developer ID,
  `get-task-allow` appears, `com.apple.application-identifier` is missing,
  `embedded.provisionprofile` is missing, the extension isn't embedded, or
  the extension Info.plist lacks `CFBundleVersion`.
- Keep `CODE_SIGN_STYLE` / `CODE_SIGN_IDENTITY` / `ENABLE_HARDENED_RUNTIME`
  out of target `base` settings in `project.yml`.
- Keep the extension `PRODUCT_NAME` equal to its bundle identifier.
- If an old development-signed extension blocks activation:
  `systemextensionsctl uninstall K39T7B8529 io.github.languel.sketchcam.camera-extension`
