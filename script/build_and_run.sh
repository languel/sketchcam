#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SketchCam"
PROJECT="SketchCam.xcodeproj"
SCHEME="SketchCam"
CONFIG="Debug"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$CONFIG/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

XCODEBUILD_PROVISIONING_ARGS=(-allowProvisioningUpdates)
if [[ "${SKETCHCAM_ALLOW_DEVICE_REGISTRATION:-0}" == "1" ]]; then
  XCODEBUILD_PROVISIONING_ARGS+=(-allowProvisioningDeviceRegistration)
fi

xcodegen generate
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  SYMROOT="$BUILD_DIR" \
  "${XCODEBUILD_PROVISIONING_ARGS[@]}" \
  build

rm -rf "$INSTALLED_APP"
/usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
shopt -s nullglob
for registered_app in \
  "$APP_BUNDLE" \
  "$BUILD_DIR"/DerivedData/Build/Products/"$CONFIG"/"$APP_NAME.app" \
  "$BUILD_DIR"/*/Build/Products/"$CONFIG"/"$APP_NAME.app" \
  "$HOME"/Library/Developer/Xcode/DerivedData/"$APP_NAME"-*/Build/Products/"$CONFIG"/"$APP_NAME.app"; do
  [[ "$registered_app" == "$INSTALLED_APP" ]] && continue
  "$LSREGISTER" -u "$registered_app" >/dev/null 2>&1 || true
done
shopt -u nullglob
"$LSREGISTER" -f -R -trusted "$INSTALLED_APP"

open_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem BEGINSWITH \"io.github.languel.sketchcam\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
