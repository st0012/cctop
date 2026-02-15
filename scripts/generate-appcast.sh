#!/bin/bash
set -euo pipefail

# generate-appcast.sh - Generate/update Sparkle appcast with per-arch ZIPs
#
# Usage:
#   ./scripts/generate-appcast.sh --version 0.7.0 arm64.zip x86_64.zip
#
# Generates the appcast using the first ZIP, then adds the second as an
# additional enclosure with sparkle:cpu attribute for multi-arch support.
#
# Environment variables:
#   SPARKLE_ED25519_PRIVATE_KEY  - Base64-encoded private key (from GitHub secret)
#   SPARKLE_PRIVATE_KEY_FILE     - Path to key file (alternative to env var)

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

# Verify generate_appcast is available. Homebrew's sparkle cask only symlinks
# the 'sparkle' binary, so add the Caskroom bin/ to PATH if needed.
if ! command -v generate_appcast >/dev/null; then
    SPARKLE_BIN=$(find "$(brew --caskroom 2>/dev/null)/sparkle" -maxdepth 2 -type d -name bin 2>/dev/null | head -1)
    if [[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN/generate_appcast" ]]; then
        export PATH="$SPARKLE_BIN:$PATH"
    else
        echo "Error: generate_appcast not found. Install with: brew install sparkle" >&2
        exit 1
    fi
fi

VERSION="${VERSION:-${SPARKLE_RELEASE_VERSION:-}}"
VERSION="${VERSION:-${GITHUB_REF_NAME:+${GITHUB_REF_NAME#v}}}"

if [[ -z "$VERSION" ]]; then
    echo "Error: Could not determine version. Use --version or set SPARKLE_RELEASE_VERSION." >&2
    exit 1
fi

DOWNLOAD_URL_PREFIX="https://github.com/st0012/cctop/releases/download/v${VERSION}/"
FEED_URL="https://raw.githubusercontent.com/st0012/cctop/master/appcast.xml"

WORK_DIR=$(mktemp -d /tmp/cctop-appcast.XXXXXX)

cleanup() {
    rm -rf "$WORK_DIR" 2>/dev/null || true
    if [[ "$CLEANUP_KEY" = true ]]; then
        rm -f "$KEY_FILE"
    fi
}
trap cleanup EXIT

# Detect architecture from ZIP filenames
detect_arch() {
    case "$1" in
        *arm64*) echo "arm64" ;;
        *x86_64*|*intel*) echo "x86_64" ;;
        *) echo "" ;;
    esac
}

# Generate appcast with the first ZIP only (generate_appcast can't handle
# multiple ZIPs with the same version). We'll add the second arch manually.
PRIMARY_ZIP="${ZIPS[0]}"
cp "$APPCAST" "$WORK_DIR/appcast.xml"
cp "$PRIMARY_ZIP" "$WORK_DIR/"

echo "==> Generating appcast for v${VERSION}..."
echo "    Primary ZIP: $(basename "$PRIMARY_ZIP")"

generate_appcast \
    --ed-key-file "$KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --link "$FEED_URL" \
    "$WORK_DIR"

cp "$WORK_DIR/appcast.xml" "$APPCAST"

PRIMARY_ARCH=$(detect_arch "$(basename "$PRIMARY_ZIP")")

# If there's a second ZIP (different arch), sign it and add as additional enclosure
if [[ ${#ZIPS[@]} -gt 1 ]]; then
    SECONDARY_ZIP="${ZIPS[1]}"
    SECONDARY_ARCH=$(detect_arch "$(basename "$SECONDARY_ZIP")")
    SECONDARY_FILENAME=$(basename "$SECONDARY_ZIP")
    SECONDARY_LENGTH=$(stat -f%z "$SECONDARY_ZIP" 2>/dev/null || stat -c%s "$SECONDARY_ZIP")

    echo "    Secondary ZIP: $SECONDARY_FILENAME (${SECONDARY_ARCH})"

    # Sign the secondary ZIP
    SIGNATURE=$(sign_update "$SECONDARY_ZIP" --ed-key-file "$KEY_FILE" 2>/dev/null | grep 'edSignature=' | sed 's/.*edSignature="\([^"]*\)".*/\1/')

    if [[ -z "$SIGNATURE" ]]; then
        # Try alternate output format
        SIGNATURE=$(sign_update "$SECONDARY_ZIP" --ed-key-file "$KEY_FILE" 2>&1)
    fi

    # Add sparkle:cpu to primary enclosure and insert secondary enclosure.
    # The generate_appcast output has a single <enclosure> per item.
    # We need to:
    # 1. Add sparkle:cpu="$PRIMARY_ARCH" to the existing enclosure
    # 2. Add a second enclosure for the secondary arch
    SECONDARY_URL="${DOWNLOAD_URL_PREFIX}${SECONDARY_FILENAME}"

    # Add cpu attribute to the primary enclosure for the current version
    if [[ -n "$PRIMARY_ARCH" ]]; then
        python3 - "$APPCAST" "$VERSION" "$PRIMARY_ARCH" "$SECONDARY_URL" "$SECONDARY_LENGTH" "$SIGNATURE" "$SECONDARY_ARCH" << 'PYEOF'
import sys, xml.etree.ElementTree as ET

appcast, version, primary_arch, sec_url, sec_len, sec_sig, sec_arch = sys.argv[1:]

# Register Sparkle namespace
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
ET.register_namespace("sparkle", ns["sparkle"])
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")

tree = ET.parse(appcast)
root = tree.getroot()

for item in root.iter("item"):
    enc = item.find("enclosure")
    if enc is None:
        continue
    # Match by version
    sv = enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}version")
    short_sv = enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString")
    if sv != version.replace(".", "") and short_sv != version:
        # Try matching build number
        try:
            build = "".join(version.split("."))
            if sv != build:
                continue
        except Exception:
            continue

    # Add cpu to primary enclosure
    enc.set("sparkle:cpu", primary_arch)

    # Create secondary enclosure
    sec_enc = ET.SubElement(item, "enclosure")
    sec_enc.set("url", sec_url)
    sec_enc.set("length", sec_len)
    sec_enc.set("type", "application/octet-stream")
    sec_enc.set("sparkle:cpu", sec_arch)
    sec_enc.set("sparkle:edSignature", sec_sig)
    # Copy version attributes from primary
    for attr in ["{http://www.andymatuschak.org/xml-namespaces/sparkle}version",
                 "{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString"]:
        val = enc.get(attr)
        if val:
            sec_enc.set(attr.split("}")[-1].replace("{", "sparkle:"), val)
    break

tree.write(appcast, xml_declaration=True, encoding="utf-8")
PYEOF
    fi
fi

echo "==> Appcast updated: $APPCAST"
echo "    Feed URL: $FEED_URL"
