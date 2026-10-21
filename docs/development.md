# Development

The XcodeGen specification, **project.yml**, is the project source of truth.
The app targets macOS 26+, and CI selects Xcode 26.5 on a macOS 26 runner.
Older macOS versions are not currently supported by the project target.

## Generate, build and test

Install Xcode and select its command-line tools, then install XcodeGen:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project SketchCam.xcodeproj -scheme SketchCam \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

Xcode resolves the committed Swift package pins, including WhisperKit. An
unsigned test build is not a distributable or activatable camera-extension build.
Follow the current repository's agent instructions when using an assistant;
build/test/app launches require an explicit request.

## Local development loop

Use the stable installed path for testing system-pointer permissions:

```sh
./script/build_and_run.sh       # development build, install in place, run
./script/run.sh                # relaunch /Applications/SketchCam.app
./script/run.sh --debug        # debug that same installed app in lldb
./script/run.sh --logs         # launch and stream app logs
./script/run.sh --telemetry    # launch and stream SketchCam subsystem logs
./script/run.sh --verify       # launch and verify the process
./script/run.sh --permissions  # open the Accessibility permissions pane
```

`script/rundebug.sh` is a compatibility alias for `script/run.sh`.
`SKETCHCAM_SKIP_XCODEGEN=1` skips regeneration when the specification is unchanged.
On a new development Mac, allow device registration when profiles are needed:

```sh
SKETCHCAM_ALLOW_DEVICE_REGISTRATION=1 ./script/build_and_run.sh
```

The helpers update `/Applications/SketchCam.app` in place with a consistent
bundle/signing identity. Avoid a separate DerivedData app for Accessibility
testing. macOS may require reapproval when the certificate or team changes.

## Signed local distribution builds

With the appropriate Apple Developer account and signing assets configured:

```sh
./script/release_build.sh       # archive → Developer ID export
./script/notarize.sh            # notarize, staple, package stapled ZIP
./script/install_release.sh     # install exported app in /Applications
./script/verify_signing.sh      # report signatures, profiles and notarization
```

The exported app is `build/Release-export/SketchCam.app`. Launch it, activate
the extension, approve in System Settings and restart the app. See
[getting started](getting-started.md) for the user installation path.

Development builds use Apple Development signing; distribution exports use
Developer ID, hardened runtime and embedded provisioning profiles. Normal
SIP-enabled camera-extension distribution uses the signed/notarized release
path. Do not replace that path with a bare `codesign` invocation that omits the
required profiles. [Notarization notes](../notes/notarization.md) record the
project-specific reasons and earlier diagnostics.

Current identifiers:

| Item | Identifier |
| --- | --- |
| App | `io.github.languel.sketchcam` |
| Camera extension | `io.github.languel.sketchcam.camera-extension` |
| App group | `$(TeamIdentifierPrefix)io.github.languel.sketchcam` |
| Team | `K39T7B8529` |

For `No Account for Team`, add the account in Xcode Settings and let automatic
signing prepare the development assets. For extension discovery failures, check
bundle naming, version keys and LaunchServices using the
[troubleshooting notes](../notes/troubleshooting.md). `systemextensionsctl list`
shows the installed extension state.

## CI and publishing

[CI distribution](ci-distribution.md) describes automatic tests, signing secrets,
notarization and artifacts. A passing `main` build produces a downloadable test
artifact when distribution is enabled; it does not publish a GitHub Release.
[Release procedure](releasing.md) covers deliberate prereleases and stable releases.

## Icon assets

The original supplied artwork is retained as `artwork/sketchcam-icon-source.png`.
Generate all macOS asset-catalog sizes and a standalone ICNS using ImageMagick:

```sh
./script/make_app_icon.sh
```

The script frames the original artwork on a rounded tile with transparent
padding. It writes the existing AppIcon asset slots and `build/icon/SketchCam.icns`;
Xcode compiles the asset catalog into the app's icon during normal builds.

## Code and design references

App behavior lives in `SketchCam` and `SketchCamCore`. The camera extension
consumes app-provided frames on a CMIO sink stream, republishes them on a source
stream and supplies fallback frames. Metal compositors/drawing/ink engines and
Core Image processing share frames through the existing rendering boundaries.
Output defaults to 1920×1080 at 30 FPS, with other formats available in Output.

See [architecture](../notes/architecture.md), [input mapping](../notes/input-mapping.md),
[ink simulation](../notes/ink-simulation.md) and [performance](../notes/performance-plan.md)
for detailed design notes. Those notes include historical investigations; the
current source, generated project specification and user docs describe the
present implementation.
