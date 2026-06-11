#!/usr/bin/env bash
# Install the exported (and ideally notarized) Release app to /Applications.
# Usage: script/install_release.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/build/Release-export/SketchCam.app"
INSTALLED="/Applications/SketchCam.app"

[[ -d "$APP" ]] || { echo "ERROR: $APP not found — run script/release_build.sh first" >&2; exit 1; }

pkill -x SketchCam >/dev/null 2>&1 || true

# A previously-activated development-signed extension must be deactivated
# before a Developer ID-signed one can activate (different signing identity).
if systemextensionsctl list 2>/dev/null | grep -q "io.github.languel.sketchcam.camera-extension"; then
  echo "NOTE: an existing SketchCamCameraExtension system extension is registered."
  echo "If activation fails after install, remove the old one with:"
  echo "  systemextensionsctl uninstall K39T7B8529 io.github.languel.sketchcam.camera-extension"
fi

rm -rf "$INSTALLED"
/usr/bin/ditto "$APP" "$INSTALLED"

# sysextd resolves the app by bundle id via LaunchServices; stale
# registrations of build-directory copies make activation fail with
# "no policy, cannot allow apps outside /Applications".
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
for copy in \
  "$ROOT_DIR"/build/Release-export/SketchCam.app \
  "$ROOT_DIR"/build/Debug/SketchCam.app \
  "$ROOT_DIR"/build/DerivedData/Build/Products/Release/SketchCam.app \
  "$ROOT_DIR"/build/DerivedData/Build/Products/Debug/SketchCam.app \
  "$ROOT_DIR"/build/SketchCam.xcarchive/Products/Applications/SketchCam.app \
  "$HOME"/Library/Developer/Xcode/DerivedData/SketchCam-*/Build/Products/*/SketchCam.app; do
  [[ -d "$copy" ]] && "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true
done
"$LSREGISTER" -f -R -trusted "$INSTALLED"

echo "Installed: $INSTALLED"
echo "Verify with: script/verify_signing.sh"
