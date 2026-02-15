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

# Validate that generate_appcast added the EdDSA signature
if ! grep -q 'sparkle:edSignature=' "$APPCAST"; then
    echo "Error: generate_appcast did not add sparkle:edSignature." >&2
    echo "    The ED25519 private key may be invalid or mismatched." >&2
    echo "    Appcast contents:" >&2
    cat "$APPCAST" >&2
    exit 1
fi

echo "    EdDSA signature: present"

PRIMARY_ARCH=$(detect_arch "$(basename "$PRIMARY_ZIP")")

# If there's a second ZIP (different arch), sign it and add as additional enclosure
if [[ ${#ZIPS[@]} -gt 1 ]]; then
    SECONDARY_ZIP="${ZIPS[1]}"
    SECONDARY_ARCH=$(detect_arch "$(basename "$SECONDARY_ZIP")")
    SECONDARY_FILENAME=$(basename "$SECONDARY_ZIP")
    SECONDARY_LENGTH=$(stat -f%z "$SECONDARY_ZIP" 2>/dev/null || stat -c%s "$SECONDARY_ZIP")
    SECONDARY_URL="${DOWNLOAD_URL_PREFIX}${SECONDARY_FILENAME}"

    echo "    Secondary ZIP: $SECONDARY_FILENAME (${SECONDARY_ARCH})"

    # Sign the secondary ZIP (fail loudly if sign_update is missing or fails)
    echo "    Signing secondary ZIP..."
    SIGN_OUTPUT=$(sign_update "$SECONDARY_ZIP" --ed-key-file "$KEY_FILE" 2>&1) || {
        echo "Error: sign_update failed:" >&2
        echo "    $SIGN_OUTPUT" >&2
        exit 1
    }

    SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'edSignature="[^"]*"' | sed 's/edSignature="//;s/"$//' || true)
    if [[ -z "$SIGNATURE" ]]; then
        echo "Error: Could not extract edSignature from sign_update output:" >&2
        echo "    $SIGN_OUTPUT" >&2
        exit 1
    fi

    echo "    Secondary signature: ${SIGNATURE:0:20}..."

    # Add sparkle:cpu to primary enclosure and insert secondary enclosure.
    # Uses regex-based string manipulation instead of Python ET to avoid
    # namespace mangling (ET drops sparkle:-prefixed attributes on rewrite).
    if [[ -n "$PRIMARY_ARCH" ]]; then
        python3 - "$APPCAST" "$VERSION" "$PRIMARY_ARCH" "$SECONDARY_URL" "$SECONDARY_LENGTH" "$SIGNATURE" "$SECONDARY_ARCH" << 'PYEOF'
import sys, re

appcast_path, version, primary_arch, sec_url, sec_len, sec_sig, sec_arch = sys.argv[1:]

with open(appcast_path) as f:
    content = f.read()

# Add sparkle:cpu to the primary enclosure (first <enclosure without sparkle:cpu)
updated, count = re.subn(
    r'(<enclosure\s)',
    r'\1sparkle:cpu="' + primary_arch + '" ',
    content,
    count=1
)
if count == 0:
    print("Error: Could not find <enclosure> tag to add sparkle:cpu", file=sys.stderr)
    sys.exit(1)
content = updated

# Extract build number from sparkle:version element
version_match = re.search(r'<sparkle:version>(\d+)</sparkle:version>', content)
build_num = version_match.group(1) if version_match else ""

# Build secondary enclosure
sec_enc = (
    f'            <enclosure sparkle:cpu="{sec_arch}" '
    f'url="{sec_url}" '
    f'sparkle:edSignature="{sec_sig}" '
    f'length="{sec_len}" '
    f'type="application/octet-stream"'
)
if build_num:
    sec_enc += f' sparkle:version="{build_num}" sparkle:shortVersionString="{version}"'
sec_enc += ' />'

# Insert secondary enclosure after the primary one
updated, count = re.subn(
    r'(<enclosure [^>]*/>\s*\n)',
    r'\g<0>' + sec_enc + '\n',
    content,
    count=1
)
if count == 0:
    print("Error: Could not insert secondary enclosure", file=sys.stderr)
    sys.exit(1)
content = updated

with open(appcast_path, 'w') as f:
    f.write(content)

print(f"    Added {sec_arch} enclosure")
PYEOF
    fi
fi

# Final validation
echo "==> Validating appcast..."
ERRORS=0

if ! grep -q 'sparkle:edSignature=' "$APPCAST"; then
    echo "    FAIL: missing sparkle:edSignature" >&2
    ERRORS=$((ERRORS + 1))
fi

if [[ ${#ZIPS[@]} -gt 1 ]]; then
    ENCLOSURE_COUNT=$(grep -c '<enclosure ' "$APPCAST" || true)
    if [[ "$ENCLOSURE_COUNT" -lt 2 ]]; then
        echo "    FAIL: expected 2 enclosures, found $ENCLOSURE_COUNT" >&2
        ERRORS=$((ERRORS + 1))
    fi
    if ! grep -q 'sparkle:cpu=' "$APPCAST"; then
        echo "    FAIL: missing sparkle:cpu attributes" >&2
        ERRORS=$((ERRORS + 1))
    fi
fi

if [[ $ERRORS -gt 0 ]]; then
    echo "    Appcast contents:" >&2
    cat "$APPCAST" >&2
    exit 1
fi

echo "    OK: all checks passed"
echo "==> Appcast updated: $APPCAST"
echo "    Feed URL: $FEED_URL"
