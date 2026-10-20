#!/usr/bin/env bash
# GitHub-hosted macOS runner only. Never prints or commits signing material.
# Developer ID archive/export uses supplied profiles, without portal mutations.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${RUNNER_TEMP:?This script requires a disposable GitHub-hosted macOS runner}"
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] \
  || { echo 'Use this script only on a GitHub-hosted Actions runner' >&2; exit 1; }
TEAM_ID="K39T7B8529"
SIGNING_DIR="$(mktemp -d "$RUNNER_TEMP/sketchcam-signing.XXXXXX")"
KEYCHAIN_PATH="$SIGNING_DIR/signing.keychain-db"
INSTALLED_PROFILES="$SIGNING_DIR/installed-profiles"
touch "$INSTALLED_PROFILES"
chmod 700 "$SIGNING_DIR"
umask 077

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  while IFS= read -r profile; do rm -f "$profile"; done < "$INSTALLED_PROFILES"
  rm -rf "$SIGNING_DIR"
}
trap cleanup EXIT

required=(MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD
  MACOS_APP_PROFILE_BASE64 MACOS_EXTENSION_PROFILE_BASE64)
if [[ -n "${APPLE_API_KEY_P8_BASE64:-}" ]]; then
  required+=(APPLE_API_KEY_P8_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID)
else
  required+=(APPLE_ID APPLE_APP_SPECIFIC_PASSWORD)
fi
missing=0
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then echo "::error::Missing GitHub Actions secret: $name"; missing=1; fi
done
[[ "$missing" == 0 ]] || exit 1

printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$SIGNING_DIR/certificate.p12"
printf '%s' "$MACOS_APP_PROFILE_BASE64" | base64 --decode > "$SIGNING_DIR/app.provisionprofile"
printf '%s' "$MACOS_EXTENSION_PROFILE_BASE64" | base64 --decode > "$SIGNING_DIR/extension.provisionprofile"
if [[ -n "${APPLE_API_KEY_P8_BASE64:-}" ]]; then
  printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$SIGNING_DIR/AuthKey.p8"
fi
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$SIGNING_DIR/certificate.p12" -k "$KEYCHAIN_PATH" \
  -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"

install_profile() {
  local input="$1" bundle_id="$2" plist="$SIGNING_DIR/$2.plist" uuid directory destination
  security cms -D -i "$input" > "$plist"
  uuid="$(python3 - "$plist" "$bundle_id" "$TEAM_ID" <<'PY'
import datetime, plistlib, sys
with open(sys.argv[1], 'rb') as f:
    profile = plistlib.load(f)
entitlements = profile.get('Entitlements', {})
expected = sys.argv[3] + '.' + sys.argv[2]
if entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier')) != expected:
    raise SystemExit('Provisioning profile does not match the expected team/bundle ID')
if not profile.get('ProvisionsAllDevices') or entitlements.get('get-task-allow', False):
    raise SystemExit('A Developer ID distribution provisioning profile is required')
if profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit('Provisioning profile has expired')
print(profile['UUID'])
PY
)"
  # Xcode versions use different profile locations; install only these two
  # profiles into each, and remove exactly those paths on exit.
  for directory in "$HOME/Library/MobileDevice/Provisioning Profiles" \
      "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    mkdir -p "$directory"
    destination="$directory/$uuid.provisionprofile"
    printf '%s\n' "$destination" >> "$INSTALLED_PROFILES"
    cp "$input" "$destination"
  done
  printf '%s' "$uuid"
}
export SKETCHCAM_APP_PROFILE
export SKETCHCAM_EXTENSION_PROFILE
SKETCHCAM_APP_PROFILE="$(install_profile "$SIGNING_DIR/app.provisionprofile" io.github.languel.sketchcam)"
SKETCHCAM_EXTENSION_PROFILE="$(install_profile "$SIGNING_DIR/extension.provisionprofile" io.github.languel.sketchcam.camera-extension)"

cd "$ROOT_DIR"
xcodegen generate --spec project.distribution.yml
mkdir -p build
xcodebuild -project SketchCam.xcodeproj -scheme SketchCam -configuration Release \
  -derivedDataPath build/DerivedData -archivePath build/SketchCam.xcarchive \
  "SKETCHCAM_APP_PROFILE=$SKETCHCAM_APP_PROFILE" \
  "SKETCHCAM_EXTENSION_PROFILE=$SKETCHCAM_EXTENSION_PROFILE" archive

python3 - "$SKETCHCAM_APP_PROFILE" "$SKETCHCAM_EXTENSION_PROFILE" "$TEAM_ID" <<'PY'
import plistlib, sys
with open('build/ExportOptions-CI.plist', 'wb') as f:
    plistlib.dump({'method': 'developer-id', 'teamID': sys.argv[3],
        'signingStyle': 'manual', 'signingCertificate': 'Developer ID Application',
        'provisioningProfiles': {'io.github.languel.sketchcam': sys.argv[1],
            'io.github.languel.sketchcam.camera-extension': sys.argv[2]}}, f)
PY
xcodebuild -exportArchive -archivePath build/SketchCam.xcarchive \
  -exportOptionsPlist build/ExportOptions-CI.plist -exportPath build/Release-export

APP="$ROOT_DIR/build/Release-export/SketchCam.app"
EXT="$APP/Contents/Library/SystemExtensions/io.github.languel.sketchcam.camera-extension.systemextension"
for bundle in "$APP" "$EXT"; do
  signature="$(codesign -dvv "$bundle" 2>&1)"
  grep -q 'Authority=Developer ID Application' <<< "$signature"
  grep -q "TeamIdentifier=$TEAM_ID" <<< "$signature"
  grep -q 'runtime' <<< "$signature"
  [[ -f "$bundle/Contents/embedded.provisionprofile" ]] || { echo "::error::Missing embedded profile"; exit 1; }
  entitlements="$(codesign -d --entitlements - "$bundle" 2>/dev/null)"
  grep -q 'com.apple.application-identifier' <<< "$entitlements" \
    || { echo '::error::Distribution bundle lacks application identifier'; exit 1; }
  if grep -q 'get-task-allow' <<< "$entitlements"; then echo '::error::Debug entitlement in distribution bundle'; exit 1; fi
done
codesign --verify --deep --strict "$APP"

if [[ -n "${APPLE_API_KEY_P8_BASE64:-}" ]]; then
  xcrun notarytool store-credentials sketchcam-ci --key "$SIGNING_DIR/AuthKey.p8" \
    --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --keychain "$KEYCHAIN_PATH"
else
  xcrun notarytool store-credentials sketchcam-ci --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$TEAM_ID" --keychain "$KEYCHAIN_PATH"
fi
bash script/notarize.sh sketchcam-ci
(cd build/Release-export && shasum -a 256 SketchCam.zip > SketchCam.zip.sha256)
