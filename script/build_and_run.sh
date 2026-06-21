#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CctopMenubar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

case "$MODE" in
  run)
    make restart
    ;;
  --verify|verify)
    make restart
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --logs|logs)
    make restart
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    make restart
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --debug|debug)
    make build
    make install
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    lldb -- "$ROOT_DIR/menubar/build/Build/Products/Debug/CctopMenubar.app/Contents/MacOS/$APP_NAME"
    ;;
  *)
    echo "usage: $0 [run|--verify|--logs|--telemetry|--debug]" >&2
    exit 2
    ;;
esac
