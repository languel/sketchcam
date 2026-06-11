#!/usr/bin/env bash
# Build a distribution-ready Release copy of SketchCam signed with
# "Developer ID Application: liubomir borissov (K39T7B8529)".
#
# Pipeline: archive (automatic development signing) → exportArchive with
# method=developer-id + signingStyle=automatic. The export step re-signs the
# app and the embedded camera extension with Developer ID, strips
# get-task-allow, injects com.apple.application-identifier, and embeds the
# Developer ID provisioning profile required by the
# com.apple.developer.system-extension.install entitlement. Do NOT replace
# this with direct `codesign`: without that embedded profile, amfid blocks
# the app from launching ("No matching profile found" / launchd error 163).
#
# Requires Xcode to be signed in to the Apple Developer account
# (cloud signing creates/downloads the Developer ID profile automatically
# via -allowProvisioningUpdates).
#
# Output: build/Release-export/SketchCam.app
#
# Usage: script/release_build.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/SketchCam.xcarchive"
EXPORT_DIR="$BUILD_DIR/Release-export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
TEAM_ID="K39T7B8529"

cd "$ROOT_DIR"

xcodegen generate

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

xcodebuild \
  -project SketchCam.xcodeproj \
  -scheme SketchCam \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  archive

mkdir -p "$BUILD_DIR"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

APP="$EXPORT_DIR/SketchCam.app"
EXT="$APP/Contents/Library/SystemExtensions/io.github.languel.sketchcam.camera-extension.systemextension"

echo
echo "Verifying export..."
[[ -d "$EXT" ]] || { echo "ERROR: extension not embedded at $EXT" >&2; exit 1; }

# capture output before grepping: grep -q on a pipe + pipefail trips SIGPIPE
app_sig="$(codesign -dvv "$APP" 2>&1)"
ext_sig="$(codesign -dvv "$EXT" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$app_sig" \
  || { echo "ERROR: app is not signed with Developer ID Application" >&2; exit 1; }
grep -q "Authority=Developer ID Application" <<<"$ext_sig" \
  || { echo "ERROR: extension is not signed with Developer ID Application" >&2; exit 1; }

app_ents="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
if grep -q get-task-allow <<<"$app_ents"; then
  echo "ERROR: get-task-allow present in Release app entitlements" >&2; exit 1
fi
grep -q "com.apple.application-identifier" <<<"$app_ents" \
  || { echo "ERROR: app missing com.apple.application-identifier (launch will fail)" >&2; exit 1; }

[[ -f "$APP/Contents/embedded.provisionprofile" ]] \
  || { echo "ERROR: app missing embedded.provisionprofile (amfid will block launch)" >&2; exit 1; }

# The SystemExtensions framework refuses to match an extension whose
# Info.plist lacks version keys (symptom: "Extension not found in App bundle").
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$EXT/Contents/Info.plist" >/dev/null 2>&1 \
  || { echo "ERROR: extension Info.plist missing CFBundleVersion" >&2; exit 1; }

codesign --verify --deep --strict "$APP"

echo
echo "Exported: $APP"
echo "Signature: Developer ID Application, hardened runtime, embedded profile, no get-task-allow ✓"
echo
echo "Next steps:"
echo "  script/notarize.sh          # submit to Apple notary service + staple"
echo "  script/install_release.sh   # copy to /Applications"
echo "  script/verify_signing.sh    # full verification report"
