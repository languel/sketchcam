#!/usr/bin/env bash
# Notarize and staple the exported Release app produced by script/release_build.sh.
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials sketchcam-notary \
#     --apple-id liuboto@gmail.com \
#     --team-id K39T7B8529
#   (generate the app-specific password at https://account.apple.com)
#
# Usage: script/notarize.sh [keychain-profile-name]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/build/Release-export/SketchCam.app"
ZIP="$ROOT_DIR/build/Release-export/SketchCam.zip"
PROFILE="${1:-sketchcam-notary}"

[[ -d "$APP" ]] || { echo "ERROR: $APP not found — run script/release_build.sh first" >&2; exit 1; }

echo "Zipping for submission..."
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple notary service (profile: $PROFILE)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling ticket to app..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo
echo "Gatekeeper assessment:"
spctl --assess --type execute --verbose "$APP"

echo
echo "Done. Install with: script/install_release.sh"
