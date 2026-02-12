#!/bin/bash
set -euo pipefail

# bundle-macos.sh - Build and bundle cctop.app (Swift-only)
#
# Usage:
#   ./scripts/bundle-macos.sh                  # Build and bundle (release)
#   ./scripts/bundle-macos.sh --skip-build     # Bundle from existing release binaries
#   ./scripts/bundle-macos.sh --arch arm64     # Build for specific architecture
#
# Output: dist/cctop.app, dist/cctop-macOS.zip

SKIP_BUILD=false
ARCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=true; shift ;;
        --arch) ARCH="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/dist"

XCODE_ARCHS="${ARCH:-$(uname -m)}"

if [ "$SKIP_BUILD" = false ]; then
    echo "==> Building CctopMenubar app..."
    xcodebuild build \
        -project "$REPO_ROOT/menubar/CctopMenubar.xcodeproj" \
        -scheme CctopMenubar \
        -configuration Release \
        -derivedDataPath "$REPO_ROOT/menubar/build/" \
        CODE_SIGN_IDENTITY="-" \
        ARCHS="$XCODE_ARCHS" \
        ONLY_ACTIVE_ARCH=NO

    echo "==> Building cctop-hook CLI..."
    xcodebuild build \
        -project "$REPO_ROOT/menubar/CctopMenubar.xcodeproj" \
        -scheme cctop-hook \
        -configuration Release \
        -derivedDataPath "$REPO_ROOT/menubar/build/" \
        CODE_SIGN_IDENTITY="-" \
        ARCHS="$XCODE_ARCHS" \
        ONLY_ACTIVE_ARCH=NO
fi

echo "==> Assembling .app bundle..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

APP="$BUILD_DIR/cctop.app"
cp -R "$REPO_ROOT/menubar/build/Build/Products/Release/CctopMenubar.app" "$APP"

# Copy cctop-hook into the app bundle
cp "$REPO_ROOT/menubar/build/Build/Products/Release/cctop-hook" "$APP/Contents/MacOS/cctop-hook"

# Ad-hoc sign (innermost first — no --deep)
echo "==> Signing app bundle..."

# Sign nested bundles/frameworks first
while IFS= read -r -d '' nested; do
    echo "  Signing $(basename "$nested")..."
    codesign --force --sign - "$nested"
done < <(find "$APP/Contents" -depth \( -name "*.bundle" -o -name "*.framework" -o -name "*.dylib" \) -print0)

# Sign cctop-hook
echo "  Signing cctop-hook..."
codesign --force --sign - "$APP/Contents/MacOS/cctop-hook"

# Sign main executable
echo "  Signing CctopMenubar..."
codesign --force --sign - "$APP/Contents/MacOS/CctopMenubar"

# Sign the overall bundle
echo "  Signing app bundle..."
codesign --force --sign - "$APP"

echo "==> Packaging..."
cd "$BUILD_DIR"
ditto -c -k --sequesterRsrc --keepParent cctop.app cctop-macOS.zip

SIZE=$(du -sh cctop.app | cut -f1)
echo "==> Done! App size: $SIZE"
echo "   App:  $APP"
echo "   Zip:  $BUILD_DIR/cctop-macOS.zip"
