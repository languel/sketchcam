#!/usr/bin/env bash
set -euo pipefail

# One canonical development loop:
#   build -> install in place at /Applications -> launch
# Accessibility approval is associated with this stable path and the app's
# designated code requirement, not with a transient DerivedData executable.

APP_NAME="SketchCam"
PROJECT="SketchCam.xcodeproj"
SCHEME="SketchCam"
CONFIG="Debug"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$CONFIG/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
MODE="${1:-run}"

usage() {
  cat >&2 <<EOF
usage: $0 [run|--debug|--logs|--telemetry|--verify|--permissions]

Builds the signed Debug app, updates /Applications/$APP_NAME.app in place,
and launches that same bundle. Use ./script/run.sh for a no-build relaunch.

Environment:
  SKETCHCAM_SKIP_XCODEGEN=1       skip project regeneration when project.yml is unchanged
  SKETCHCAM_CODESIGN_IDENTITY=... choose a stable signing identity explicitly
  SKETCHCAM_ALLOW_DEVICE_REGISTRATION=1  allow provisioning device registration
EOF
}

case "$MODE" in
  run|debug|--debug|--logs|logs|--telemetry|telemetry|--verify|verify|--permissions|permissions) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

cd "$ROOT_DIR"

if [[ "$MODE" == "permissions" || "$MODE" == "--permissions" ]]; then
  /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  echo "Approve /Applications/$APP_NAME.app, then click Refresh in Input Map."
  exit 0
fi

# Quit the installed app before replacing its executable. Do not use the
# DerivedData product as the development runtime: it is not the app approved
# in Accessibility and it is not the bundle used by the camera extension.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ "${SKETCHCAM_SKIP_XCODEGEN:-0}" != "1" && ( ! -e "$PROJECT" || project.yml -nt "$PROJECT/project.pbxproj" ) ]]; then
  xcodegen generate
fi

XCODEBUILD_PROVISIONING_ARGS=(-allowProvisioningUpdates)
if [[ "${SKETCHCAM_ALLOW_DEVICE_REGISTRATION:-0}" == "1" ]]; then
  XCODEBUILD_PROVISIONING_ARGS+=(-allowProvisioningDeviceRegistration)
fi

CODE_SIGN_IDENTITY="${SKETCHCAM_CODESIGN_IDENTITY:-Apple Development}"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  SYMROOT="$BUILD_DIR" \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  "${XCODEBUILD_PROVISIONING_ARGS[@]}" \
  build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Build succeeded but $APP_BUNDLE was not produced." >&2
  exit 1
fi

old_requirement=""
if [[ -d "$INSTALLED_APP" ]]; then
  old_requirement="$(/usr/bin/codesign -d -r- "$INSTALLED_APP" 2>&1 | sed -n '/designated =>/p' || true)"
fi
new_requirement="$(/usr/bin/codesign -d -r- "$APP_BUNDLE" 2>&1 | sed -n '/designated =>/p' || true)"

# Update the existing bundle in place. Keeping the bundle directory at the
# same path avoids needless LaunchServices/TCC churn between iterations.
mkdir -p "$INSTALLED_APP"
/usr/bin/ditto --rsrc --extattr "$APP_BUNDLE" "$INSTALLED_APP"

if [[ -n "$old_requirement" && "$old_requirement" != "$new_requirement" ]]; then
  echo "Warning: the app's designated code requirement changed; macOS may require one-time Accessibility reapproval." >&2
fi

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

echo "Installed and will run $INSTALLED_APP"
echo "Stable code requirement: $new_requirement"

open_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

wait_for_process() {
  for _ in {1..20}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "$APP_NAME did not start from $INSTALLED_APP" >&2
  return 1
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
    wait_for_process
    echo "$APP_NAME is running from $INSTALLED_APP"
    ;;
esac
