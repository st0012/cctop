#!/bin/bash
set -euo pipefail

# sign-and-notarize.sh - Sign and notarize the cctop.app bundle
#
# Usage:
#   ./scripts/sign-and-notarize.sh dist/cctop.app
#   ./scripts/sign-and-notarize.sh --dry-run dist/cctop.app
#
# Required environment variables (unless --dry-run):
#   APPLE_IDENTITY       - Signing identity (e.g. "Developer ID Application: Name (TEAMID)")
#   APPLE_TEAM_ID        - Apple Team ID
#   APPLE_ID             - Apple ID email
#   APPLE_APP_PASSWORD   - App-specific password for notarytool
#
# The script signs each Mach-O binary individually (not --deep),
# then submits the app for notarization and staples the ticket.

DRY_RUN=false
APP_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        *) APP_PATH="$1"; shift ;;
    esac
done

if [ -z "$APP_PATH" ]; then
    echo "Usage: $0 [--dry-run] <path-to-.app>"
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH does not exist or is not a directory"
    exit 1
fi

# Resolve to absolute path
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"

ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/menubar/CctopMenubar/CctopMenubar.entitlements"

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Error: Entitlements file not found at $ENTITLEMENTS"
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo "==> DRY RUN: would sign and notarize $APP_PATH"
    echo ""
    echo "Signing order:"
    echo "  1. $APP_PATH/Contents/MacOS/cctop-hook"
    echo "  2. $APP_PATH/Contents/MacOS/cctop"
    echo "  3. $APP_PATH/Contents/MacOS/CctopMenubar"
    echo "  4. $APP_PATH (bundle)"
    echo ""
    echo "Entitlements: $ENTITLEMENTS"
    echo ""
    echo "Required env vars:"
    echo "  APPLE_IDENTITY     = ${APPLE_IDENTITY:-(not set)}"
    echo "  APPLE_TEAM_ID      = ${APPLE_TEAM_ID:-(not set)}"
    echo "  APPLE_ID           = ${APPLE_ID:-(not set)}"
    echo "  APPLE_APP_PASSWORD = ${APPLE_APP_PASSWORD:+(set)}"
    [ -z "${APPLE_APP_PASSWORD:-}" ] && echo "  APPLE_APP_PASSWORD = (not set)"
    echo ""
    echo "Post-sign steps:"
    echo "  1. Create zip with ditto"
    echo "  2. Submit to notarytool"
    echo "  3. Staple ticket to .app"
    exit 0
fi

# Validate required env vars
for var in APPLE_IDENTITY APPLE_TEAM_ID APPLE_ID APPLE_APP_PASSWORD; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set"
        exit 1
    fi
done

CODESIGN_ARGS=(
    --force
    --timestamp
    --options runtime
    --sign "$APPLE_IDENTITY"
    --entitlements "$ENTITLEMENTS"
)

echo "==> Signing individual binaries..."

# Sign helper binaries first (innermost to outermost)
echo "  Signing cctop-hook..."
codesign "${CODESIGN_ARGS[@]}" "$APP_PATH/Contents/MacOS/cctop-hook"

echo "  Signing cctop..."
codesign "${CODESIGN_ARGS[@]}" "$APP_PATH/Contents/MacOS/cctop"

# Sign the main executable
echo "  Signing CctopMenubar..."
codesign "${CODESIGN_ARGS[@]}" "$APP_PATH/Contents/MacOS/CctopMenubar"

# Sign the overall bundle
echo "  Signing app bundle..."
codesign "${CODESIGN_ARGS[@]}" "$APP_PATH"

echo "==> Verifying signature..."
codesign --verify --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH" || echo "  (spctl check may fail without notarization)"

echo "==> Creating zip for notarization..."
NOTARIZE_ZIP="$(dirname "$APP_PATH")/cctop-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

rm -f "$NOTARIZE_ZIP"

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "==> Verifying notarization..."
spctl --assess --type execute --verbose=2 "$APP_PATH"

echo "==> Done! $APP_PATH is signed and notarized."
