#!/bin/bash
# bundle-macos.sh - Create a macOS .app bundle for cctop-menubar
#
# Usage:
#   ./scripts/bundle-macos.sh                  # Build and bundle (release)
#   ./scripts/bundle-macos.sh --skip-build     # Bundle from existing release binaries
#   ./scripts/bundle-macos.sh --target aarch64-apple-darwin  # Cross-compile target
#
# Output: dist/cctop.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/cctop.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

SKIP_BUILD=false
TARGET=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-build] [--target <triple>]"
            exit 1
            ;;
    esac
done

# Read version from Cargo.toml
VERSION=$(grep '^version' "$PROJECT_DIR/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
echo "Building cctop v${VERSION} .app bundle..."

# Build release binaries if needed
if [ "$SKIP_BUILD" = false ]; then
    echo "Building release binaries..."
    if [ -n "$TARGET" ]; then
        cargo build --release --target "$TARGET" --manifest-path "$PROJECT_DIR/Cargo.toml"
        BINARY_DIR="$PROJECT_DIR/target/$TARGET/release"
    else
        cargo build --release --manifest-path "$PROJECT_DIR/Cargo.toml"
        BINARY_DIR="$PROJECT_DIR/target/release"
    fi
else
    if [ -n "$TARGET" ]; then
        BINARY_DIR="$PROJECT_DIR/target/$TARGET/release"
    else
        BINARY_DIR="$PROJECT_DIR/target/release"
    fi
fi

# Verify binaries exist
for bin in cctop-menubar cctop-hook cctop; do
    if [ ! -f "$BINARY_DIR/$bin" ]; then
        echo "Error: $BINARY_DIR/$bin not found. Run without --skip-build first."
        exit 1
    fi
done

# Clean and create bundle structure
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Write Info.plist
cat > "$CONTENTS_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>cctop</string>
    <key>CFBundleDisplayName</key>
    <string>cctop</string>
    <key>CFBundleIdentifier</key>
    <string>com.st0012.cctop</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>cctop-menubar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Copy binaries
cp "$BINARY_DIR/cctop-menubar" "$MACOS_DIR/cctop-menubar"
cp "$BINARY_DIR/cctop-hook" "$MACOS_DIR/cctop-hook"
cp "$BINARY_DIR/cctop" "$MACOS_DIR/cctop"

# Copy app icon if it exists
if [ -f "$PROJECT_DIR/assets/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Strip debug symbols to reduce size (optional, safe for release builds)
strip "$MACOS_DIR/cctop-menubar" 2>/dev/null || true
strip "$MACOS_DIR/cctop-hook" 2>/dev/null || true
strip "$MACOS_DIR/cctop" 2>/dev/null || true

# Ad-hoc sign (required for arm64 macOS, sufficient for local use)
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

# Report results
MENUBAR_SIZE=$(du -sh "$MACOS_DIR/cctop-menubar" | cut -f1)
HOOK_SIZE=$(du -sh "$MACOS_DIR/cctop-hook" | cut -f1)
TUI_SIZE=$(du -sh "$MACOS_DIR/cctop" | cut -f1)
APP_SIZE=$(du -sh "$APP_DIR" | cut -f1)

echo ""
echo "Bundle created: $APP_DIR"
echo "  cctop-menubar: $MENUBAR_SIZE"
echo "  cctop-hook:    $HOOK_SIZE"
echo "  cctop (TUI):   $TUI_SIZE"
echo "  Total:         $APP_SIZE"
echo ""
echo "To install: cp -r $APP_DIR /Applications/"
echo "To create zip: cd $DIST_DIR && zip -r cctop-macOS.zip cctop.app"
