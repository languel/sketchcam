#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SketchCam"
CONFIG="Debug"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<EOF
usage: $0 [run|--debug|--logs|--telemetry|--verify|--print]

Runs the newest existing local $CONFIG $APP_NAME.app without rebuilding or
installing to /Applications. Use ./script/build_and_run.sh when you want a
fresh build installed to /Applications for system-extension activation.
EOF
}

find_latest_app() {
  /usr/bin/find \
    "$ROOT_DIR/build" \
    "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*/Build/Products/$CONFIG/$APP_NAME.app" \
    -type d \
    -prune \
    -print0 2>/dev/null |
    /usr/bin/xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null |
    /usr/bin/sort -nr |
    /usr/bin/head -n 1 |
    /usr/bin/cut -d' ' -f2-
}

APP_BUNDLE="$(find_latest_app)"

if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
  echo "No $CONFIG $APP_NAME.app found. Build one first:" >&2
  echo "  ./script/build_and_run.sh" >&2
  exit 1
fi

MODE="${1:-run}"

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem BEGINSWITH \"io.github.languel.sketchcam\""
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --print|print)
    printf '%s\n' "$APP_BUNDLE"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
