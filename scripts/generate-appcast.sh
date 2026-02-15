#!/bin/bash
set -euo pipefail

# generate-appcast.sh - Generate/update Sparkle appcast with signed ZIP(s)
#
# Usage:
#   ./scripts/generate-appcast.sh cctop-macOS-arm64.zip cctop-macOS-x86_64.zip
#   ./scripts/generate-appcast.sh --version 0.7.0 cctop-macOS-arm64.zip
#
# Supports multiple ZIPs (one per architecture). Each gets its own enclosure
# with sparkle:cpu attribute in the same appcast item.
#
# Environment variables:
#   SPARKLE_ED25519_PRIVATE_KEY  - Base64-encoded private key (from GitHub secret)
#   SPARKLE_PRIVATE_KEY_FILE     - Path to key file (alternative to env var)
#   SPARKLE_RELEASE_VERSION      - Override version (default: extracted from app bundle)
#
# Output: Updates appcast.xml in the repo root.

VERSION=""
ZIPS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) ZIPS+=("$1"); shift ;;
    esac
done

if [[ ${#ZIPS[@]} -eq 0 ]]; then
    echo "Usage: $0 [--version X.Y.Z] <zip-file> [zip-file...]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPCAST="$REPO_ROOT/appcast.xml"

if [[ ! -f "$APPCAST" ]]; then
    echo "Error: appcast.xml not found at $APPCAST"
    exit 1
fi

# Resolve the ED25519 private key
KEY_FILE=""
CLEANUP_KEY=false

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    KEY_FILE="$SPARKLE_PRIVATE_KEY_FILE"
elif [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
    # Write base64-encoded key from env var to temp file
    KEY_FILE=$(mktemp /tmp/sparkle-key.XXXXXX)
    CLEANUP_KEY=true
    printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" > "$KEY_FILE"
else
    echo "Error: Set SPARKLE_ED25519_PRIVATE_KEY or SPARKLE_PRIVATE_KEY_FILE." >&2
    exit 1
fi

if [[ ! -f "$KEY_FILE" ]]; then
    echo "Error: Key file not found: $KEY_FILE" >&2
    exit 1
fi

# Verify generate_appcast is available
if ! command -v generate_appcast >/dev/null; then
    echo "Error: generate_appcast not found. Install with: brew install sparkle" >&2
    exit 1
fi

# Determine version from tag or app bundle
if [[ -z "$VERSION" ]]; then
    VERSION="${SPARKLE_RELEASE_VERSION:-}"
fi
if [[ -z "$VERSION" && -n "${GITHUB_REF_NAME:-}" ]]; then
    VERSION="${GITHUB_REF_NAME#v}"
fi
if [[ -z "$VERSION" ]]; then
    echo "Error: Could not determine version. Use --version or set SPARKLE_RELEASE_VERSION." >&2
    exit 1
fi

DOWNLOAD_URL_PREFIX="https://github.com/st0012/cctop/releases/download/v${VERSION}/"
FEED_URL="https://raw.githubusercontent.com/st0012/cctop/master/appcast.xml"

# Work in a temp directory (generate_appcast operates on a directory)
WORK_DIR=$(mktemp -d /tmp/cctop-appcast.XXXXXX)

cleanup() {
    rm -r "$WORK_DIR" 2>/dev/null || true
    if [[ "$CLEANUP_KEY" = true ]]; then
        rm -f "$KEY_FILE"
    fi
}
trap cleanup EXIT

# Copy existing appcast and all ZIPs into the work directory
cp "$APPCAST" "$WORK_DIR/appcast.xml"

for zip in "${ZIPS[@]}"; do
    if [[ ! -f "$zip" ]]; then
        echo "Error: ZIP not found: $zip" >&2
        exit 1
    fi
    cp "$zip" "$WORK_DIR/"
done

echo "==> Generating appcast for v${VERSION}..."
echo "    ZIPs: ${ZIPS[*]}"
echo "    Download prefix: $DOWNLOAD_URL_PREFIX"

# Run generate_appcast — it discovers ZIPs in the directory, reads the app
# bundle inside each to extract version/build number, signs with ED25519,
# and updates appcast.xml with new entries (including per-arch enclosures).
generate_appcast \
    --ed-key-file "$KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --link "$FEED_URL" \
    "$WORK_DIR"

# Copy the updated appcast back to the repo
cp "$WORK_DIR/appcast.xml" "$APPCAST"

echo "==> Appcast updated: $APPCAST"
echo "    Feed URL: $FEED_URL"
