#!/usr/bin/env bash
set -euo pipefail

# No-build companion to build_and_run.sh. Always run the installed bundle so
# the executable matches the Accessibility approval and camera-extension path.
APP_NAME="SketchCam"
INSTALLED_APP="/Applications/$APP_NAME.app"
MODE="${1:-run}"

usage() {
  cat >&2 <<EOF
usage: $0 [run|--debug|--logs|--telemetry|--verify|--print|--build]

Runs the current /Applications/$APP_NAME.app without rebuilding.
Use ./script/build_and_run.sh for a fresh build and install.
EOF
}

if [[ "$MODE" == "--build" || "$MODE" == "build" ]]; then
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_and_run.sh" run
fi

if [[ ! -d "$INSTALLED_APP" ]]; then
  echo "No installed $APP_NAME.app found at $INSTALLED_APP." >&2
  echo "Run ./script/build_and_run.sh once, then use this script for quick relaunches." >&2
  exit 1
fi

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
    /usr/bin/open -n "$INSTALLED_APP"
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    /usr/bin/open -n "$INSTALLED_APP"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$INSTALLED_APP"
    /usr/bin/log stream --info --style compact --predicate "subsystem BEGINSWITH \"io.github.languel.sketchcam\""
    ;;
  --verify|verify)
    /usr/bin/open -n "$INSTALLED_APP"
    wait_for_process
    echo "$APP_NAME is running from $INSTALLED_APP"
    ;;
  --permissions|permissions)
    /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    echo "Approve $INSTALLED_APP, then click Refresh in Input Map."
    ;;
  --print|print)
    printf '%s\n' "$INSTALLED_APP"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
