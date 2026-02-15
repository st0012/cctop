#!/bin/bash
set -euo pipefail

# sign-and-notarize.sh - Sign and notarize the cctop.app bundle
#
# Usage:
#   ./scripts/sign-and-notarize.sh dist/cctop.app
#   ./scripts/sign-and-notarize.sh --dry-run dist/cctop.app
#   ./scripts/sign-and-notarize.sh --sign-only dist/cctop.app
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
SIGN_ONLY=false
APP_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --sign-only) SIGN_ONLY=true; shift ;;
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

# Discover all signable items in the bundle, innermost first.
#
# Signing order matters for notarization — inner items must be signed
# before their enclosing bundle. This handles Sparkle.framework's nested
# structure: XPC services, helper apps (Autoupdate.app, Updater.app),
# and executables inside those bundles.
#
# Order: dylibs -> inner executables -> nested bundles (depth-first) -> main exec -> app bundle
discover_signable_items() {
    local app="$1"
    local items=()

    # 1. Shared libraries (dylibs) anywhere in the bundle
    while IFS= read -r -d '' item; do
        items+=("$item")
    done < <(find "$app/Contents" -type f -name '*.dylib' -print0 2>/dev/null)

    # 2. Mach-O executables inside nested bundles (frameworks, XPCs, helper apps).
    #    These must be signed BEFORE their enclosing bundle directory.
    #    Scan all MacOS/ dirs inside Contents/ (not just the top-level one).
    local main_exec
    main_exec="$app/Contents/MacOS/$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null || basename "$app" .app)"
    while IFS= read -r -d '' item; do
        # Skip the main app executable -- signed with the app bundle at the end
        [ "$item" = "$main_exec" ] && continue
        # Skip dylibs -- already signed in step 1
        [[ "$item" == *.dylib ]] && continue
        items+=("$item")
    done < <(find "$app/Contents" -type f -perm +111 -path "*/MacOS/*" -print0 2>/dev/null)

    # 3. Nested signable bundles (depth-first so innermost are signed first).
    #    Includes: *.xpc (Sparkle Downloader/Installer), *.app (Sparkle Autoupdate/Updater),
    #    *.bundle, *.framework, *.appex
    while IFS= read -r -d '' item; do
        items+=("$item")
    done < <(find "$app/Contents" -depth -type d \
        \( -name '*.xpc' -o -name '*.app' -o -name '*.appex' -o -name '*.bundle' -o -name '*.framework' \) \
        -print0 2>/dev/null)

    # 4. Main executable
    if [ -f "$main_exec" ]; then
        items+=("$main_exec")
    fi

    # 5. The app bundle itself
    items+=("$app")

    printf '%s\n' "${items[@]}"
}

SIGNABLE_ITEMS=$(discover_signable_items "$APP_PATH")

if [ "$DRY_RUN" = true ]; then
    echo "==> DRY RUN: would sign and notarize $APP_PATH"
    echo ""
    echo "Signing order:"
    i=1
    while IFS= read -r item; do
        echo "  $i. $item"
        ((i++))
    done <<< "$SIGNABLE_ITEMS"
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

echo "==> Signing all code in bundle..."
while IFS= read -r item; do
    echo "  Signing $(basename "$item")..."
    codesign "${CODESIGN_ARGS[@]}" "$item"
done <<< "$SIGNABLE_ITEMS"

echo "==> Verifying signature..."
codesign --verify --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH" || echo "  (spctl check may fail without notarization)"

if [ "$SIGN_ONLY" = true ]; then
    echo "==> Done! $APP_PATH is signed (notarization skipped)."
    exit 0
fi

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
