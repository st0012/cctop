#!/bin/bash
set -euo pipefail

# create-dmg.sh - Create a DMG installer with drag-to-Applications layout
#
# Prerequisites:
#   brew install create-dmg
#
# Usage:
#   ./scripts/create-dmg.sh                        # Uses dist/cctop.app
#   ./scripts/create-dmg.sh path/to/cctop.app      # Custom .app path
#   ./scripts/create-dmg.sh --arch arm64            # Set arch suffix in output filename
#
# Output: dist/cctop-macOS-<arch>.dmg (or dist/cctop-macOS.dmg if no arch)

ARCH=""
APP_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        *) APP_PATH="$1"; shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"

APP_PATH="${APP_PATH:-$DIST_DIR/cctop.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found. Build with ./scripts/bundle-macos.sh first."
    exit 1
fi

if ! command -v create-dmg &>/dev/null; then
    echo "Error: create-dmg not found. Install with: brew install create-dmg"
    exit 1
fi

if [ -n "$ARCH" ]; then
    DMG_NAME="cctop-macOS-${ARCH}.dmg"
else
    DMG_NAME="cctop-macOS.dmg"
fi

DMG_PATH="$DIST_DIR/$DMG_NAME"

# Remove existing DMG if present
rm -f "$DMG_PATH"

echo "==> Creating DMG from $APP_PATH..."

create-dmg \
    --volname "cctop" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "cctop.app" 175 190 \
    --app-drop-link 425 190 \
    --hide-extension "cctop.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"

SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo "==> Done! DMG size: $SIZE"
echo "   DMG: $DMG_PATH"
