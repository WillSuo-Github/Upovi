#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="Upovi"
BUNDLE_ID="app.upovi.Upovi"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="${UPOVI_OUTPUT_DIR:-$ROOT_DIR/dist}/$APP_NAME.app"
if [[ "$MODE" == "--verify-existing" ]]; then
  codesign --verify --deep --strict "$APP_BUNDLE"
  /usr/bin/open -n "$APP_BUNDLE"
  sleep 2
  /usr/sbin/lsof -t "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null
  echo "Upovi existing bundle launch verified: $APP_BUNDLE"
  exit 0
fi
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
CONFIGURATION="${CONFIGURATION:-debug}" UPOVI_STAGE_ONLY=1 ./script/package_release.sh
case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify|verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "Upovi launch verified: $APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Upovi"' ;;
  --telemetry|telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "app.upovi.Upovi"' ;;
  *) echo "usage: $0 [run|--verify|--verify-existing|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
