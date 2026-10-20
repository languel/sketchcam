# Automatic signed and notarized builds

The **Build and Test** GitHub Actions workflow tests pushes to `main` and
`codex/**`, and pull requests targeting `main`. Once configured below, successful
`main` pushes also run **Signed and notarized app**. This job archives, exports
with Developer ID, submits to Apple, staples the accepted ticket, assesses with
Gatekeeper, and uploads `SketchCam.zip` plus its SHA-256 checksum as an Actions
artifact retained for 14 days. It does not publish a GitHub Release or install
the app anywhere. Manual **Run workflow** on `main` follows the same test gate.
PRs and other branches never receive distribution credentials through this job.

## One-time setup

The repository had no Actions signing secrets when this workflow was added.
Keep `MACOS_DISTRIBUTION_ENABLED` unset until the assets below are configured.
Missing assets mean signing/notarization cannot be verified end to end.

Open repository **Settings → Secrets and variables → Actions**, or use
`gh secret set`. Add these repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of the **Developer ID Application** certificate and its private key exported as a password-protected `.p12` from Keychain Access. |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting that `.p12`. |
| `MACOS_APP_PROFILE_BASE64` | Base64 of the **Developer ID** provisioning profile for `io.github.languel.sketchcam`. |
| `MACOS_EXTENSION_PROFILE_BASE64` | Base64 of the **Developer ID** profile for `io.github.languel.sketchcam.camera-extension`. |
| `APPLE_API_KEY_P8_BASE64` | Base64 of an App Store Connect **team** API key `.p8` authorized for notarization. |
| `APPLE_API_KEY_ID` | The API key's Key ID. |
| `APPLE_API_ISSUER_ID` | The API key's Issuer ID. |

Use team `K39T7B8529`. Profiles must include the relevant app-group and
system-extension capabilities from this project's entitlements, match the
exported certificate, and be current. Development/App Store profiles cannot
replace Developer ID profiles. A certificate without its private key cannot
sign. The CI pipeline does not create certificates/profiles or register devices.

For each file secret, pipe Base64 directly to GitHub rather than into chat,
source code, or a checked-in file. For example, substituting your actual path:

```sh
base64 -i /path/to/DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64
base64 -i /path/to/App.provisionprofile | gh secret set MACOS_APP_PROFILE_BASE64
base64 -i /path/to/Extension.provisionprofile | gh secret set MACOS_EXTENSION_PROFILE_BASE64
base64 -i /path/to/AuthKey.p8 | gh secret set APPLE_API_KEY_P8_BASE64
gh secret set MACOS_CERTIFICATE_PASSWORD
gh secret set APPLE_API_KEY_ID
gh secret set APPLE_API_ISSUER_ID
```

After all seven are set, add repository **variable**
`MACOS_DISTRIBUTION_ENABLED=true` (not a secret):

```sh
gh variable set MACOS_DISTRIBUTION_ENABLED --body true
gh workflow run ci.yml --ref main
```

Enabling the variable opts future successful `main` pushes into automatic
distribution. Remove it or set it to `false` to stop signing jobs while keeping
ordinary build/test CI active. No local signing keys are automatically exported
or uploaded by these scripts.

## Download and test

Open **Actions → Build and Test → the successful run → Artifacts**. Download
`SketchCam-notarized-<commit>`, unpack that outer artifact ZIP, then unpack
`SketchCam.zip`. The inner ZIP is recreated **after** stapling, so its app
contains the notarization ticket. Optional checksum check from that directory:

```sh
shasum -a 256 -c SketchCam.zip.sha256
```

Move `SketchCam.app` to `/Applications`, launch it, activate the camera extension,
approve it in System Settings, then restart the app. Test microphone permissions,
speech captions, and the virtual-camera feed on the downloaded build. Passing
CI signing/notarization checks is not a live device or camera-extension test.

## Implementation and failure handling

`script/ci_release.sh` imports the certificate into a temporary runner keychain,
checks profile bundle IDs/type/expiry, and installs both profiles. The CI-only
`project.distribution.yml` overlays manual Developer ID archive signing on the
normal XcodeGen specification. `xcodebuild -exportArchive` preserves the
provisioning/entitlement distribution path used by the existing release scripts;
the pipeline checks app and extension Developer ID identities, team, hardened
runtime, embedded profiles and absence of debug entitlements before notarizing.

Notary credentials live only in the temporary keychain. The script's exit trap
deletes that keychain, credential files and the installed profiles. Runners are
GitHub-hosted/disposable. Do not run this CI script on a personal/self-hosted Mac;
local releases continue to use `script/release_build.sh` and `script/notarize.sh`.
Only the final ZIP/checksum are uploaded, never signing files or the archive.

If tests fail, the distribution job waits/skips. If credentials, profiles,
signing, notarization, stapling or Gatekeeper assessment fail, it uploads no app.
Check the failed job log. Once fixed, rerun the workflow on `main`. The initial
workflow changes were checked for YAML/shell syntax and whitespace; a real
signed/notarized CI artifact remains unverified until credentials are supplied.

References: [GitHub's certificate and profile setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[Apple's distribution signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/),
and the project's [local notarization notes](../notes/notarization.md).
