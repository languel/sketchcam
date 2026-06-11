#!/usr/bin/env bash
# Print a full signing/notarization/system-extension report for an installed
# (or exported) SketchCam.app.
#
# Usage: script/verify_signing.sh [path-to-SketchCam.app]   (default: /Applications/SketchCam.app)
set -uo pipefail

APP="${1:-/Applications/SketchCam.app}"
EXT="$APP/Contents/Library/SystemExtensions/io.github.languel.sketchcam.camera-extension.systemextension"

[[ -d "$APP" ]] || { echo "ERROR: $APP not found" >&2; exit 1; }

section() { echo; echo "=== $1 ==="; }

section "App signature ($APP)"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier=|Authority=|TeamIdentifier=|Signature=|flags=|Runtime Version="

section "Extension signature ($EXT)"
if [[ -d "$EXT" ]]; then
  codesign -dv --verbose=4 "$EXT" 2>&1 | grep -E "Identifier=|Authority=|TeamIdentifier=|Signature=|flags=|Runtime Version="
else
  echo "MISSING: extension not embedded at expected path"
fi

section "Deep signature verification"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1

section "App entitlements"
codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p - 2>/dev/null || codesign -d --entitlements - "$APP" 2>/dev/null

section "Extension entitlements"
[[ -d "$EXT" ]] && { codesign -d --entitlements :- "$EXT" 2>/dev/null | plutil -p - 2>/dev/null || codesign -d --entitlements - "$EXT" 2>/dev/null; }

section "get-task-allow check (must be absent in Release)"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "WARNING: app has get-task-allow (development build)"
else
  echo "OK: app has no get-task-allow"
fi
if [[ -d "$EXT" ]] && codesign -d --entitlements - "$EXT" 2>/dev/null | grep -q "get-task-allow"; then
  echo "WARNING: extension has get-task-allow (development build)"
else
  echo "OK: extension has no get-task-allow"
fi

section "Embedded provisioning profiles"
found_profile=0
while IFS= read -r profile; do
  found_profile=1
  name="$(security cms -D -i "$profile" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)"
  echo "$profile -> ${name:-unreadable}"
done < <(find "$APP" -name "embedded.provisionprofile" 2>/dev/null)
[[ $found_profile -eq 0 ]] && echo "none (expected for Developer ID builds)"

section "Notarization (stapled ticket)"
xcrun stapler validate "$APP" 2>&1

section "Gatekeeper assessment (spctl)"
spctl --assess --type execute --verbose "$APP" 2>&1

section "System extensions (systemextensionsctl list)"
systemextensionsctl list 2>&1

exit 0
