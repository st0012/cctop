#!/bin/bash
set -euo pipefail

# bundle-macos.sh - Build and bundle the hybrid Swift + Rust cctop.app
#
# Usage:
#   ./scripts/bundle-macos.sh                  # Build and bundle (release)
#   ./scripts/bundle-macos.sh --skip-build     # Bundle from existing release binaries
#   ./scripts/bundle-macos.sh --target aarch64-apple-darwin  # Cross-compile target
#
# Output: dist/cctop.app, dist/cctop-macOS.zip

SKIP_BUILD=false
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=true; shift ;;
        --target) TARGET="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/dist"

if [ "$SKIP_BUILD" = false ]; then
    echo "==> Building Rust binaries..."
    if [ -n "$TARGET" ]; then
        cargo build --release --manifest-path "$REPO_ROOT/Cargo.toml" --target "$TARGET"
        RUST_BIN="$REPO_ROOT/target/$TARGET/release"
    else
        cargo build --release --manifest-path "$REPO_ROOT/Cargo.toml"
        RUST_BIN="$REPO_ROOT/target/release"
    fi

    echo "==> Building Swift menubar app..."
    XCODE_ARCHS=""
    case "$TARGET" in
        aarch64-apple-darwin) XCODE_ARCHS="arm64" ;;
        x86_64-apple-darwin) XCODE_ARCHS="x86_64" ;;
        *) XCODE_ARCHS="$(uname -m)" ;;
    esac
    xcodebuild build \
        -project "$REPO_ROOT/menubar/CctopMenubar.xcodeproj" \
        -scheme CctopMenubar \
        -configuration Release \
        -derivedDataPath "$REPO_ROOT/menubar/build/" \
        CODE_SIGN_IDENTITY="-" \
        ARCHS="$XCODE_ARCHS" \
        ONLY_ACTIVE_ARCH=NO
else
    if [ -n "$TARGET" ]; then
        RUST_BIN="$REPO_ROOT/target/$TARGET/release"
    else
        RUST_BIN="$REPO_ROOT/target/release"
    fi
fi

echo "==> Assembling .app bundle..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

APP="$BUILD_DIR/cctop.app"
cp -R "$REPO_ROOT/menubar/build/Build/Products/Release/CctopMenubar.app" "$APP"

# Inject Rust binaries
cp "$RUST_BIN/cctop" "$APP/Contents/MacOS/cctop"
cp "$RUST_BIN/cctop-hook" "$APP/Contents/MacOS/cctop-hook"

# Strip binaries
strip "$APP/Contents/MacOS/cctop"
strip "$APP/Contents/MacOS/cctop-hook"

# Ad-hoc re-sign (per-binary, innermost first — no --deep)
echo "==> Signing app bundle..."

# Sign nested bundles/frameworks first
while IFS= read -r -d '' nested; do
    echo "  Signing $(basename "$nested")..."
    codesign --force --sign - "$nested"
done < <(find "$APP/Contents" -depth \( -name "*.bundle" -o -name "*.framework" -o -name "*.dylib" \) -print0)

# Sign injected Rust binaries
echo "  Signing cctop-hook..."
codesign --force --sign - "$APP/Contents/MacOS/cctop-hook"
echo "  Signing cctop..."
codesign --force --sign - "$APP/Contents/MacOS/cctop"

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
