#!/bin/bash
set -euo pipefail

# render-og.sh - Render site/og.html to site/og.png (1200x630)
#
# Run this after editing site/og.html. Commit the resulting site/og.png
# in the same commit so the social preview stays in sync with its source.
#
# Usage:
#   scripts/render-og.sh
#   CHROME_BIN=/path/to/chrome scripts/render-og.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OG_HTML="$REPO_ROOT/site/og.html"
OG_PNG="$REPO_ROOT/site/og.png"

if [ ! -f "$OG_HTML" ]; then
    echo "Error: $OG_HTML not found" >&2
    exit 1
fi

CHROME="${CHROME_BIN:-}"
if [ -z "$CHROME" ]; then
    for candidate in \
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "/Applications/Chromium.app/Contents/MacOS/Chromium" \
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
        "$(command -v google-chrome 2>/dev/null || true)" \
        "$(command -v chromium 2>/dev/null || true)"
    do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            CHROME="$candidate"
            break
        fi
    done
fi

if [ -z "$CHROME" ]; then
    echo "Error: no Chromium-family browser found." >&2
    echo "Install Google Chrome, or set CHROME_BIN to a Chromium binary." >&2
    exit 1
fi

# Fresh user-data-dir each run — Chrome aggressively caches resources
# (including Google Fonts CSS) across runs from the same profile, which
# silently produces stale renders when og.html's font set changes.
USER_DATA_DIR="$(mktemp -d -t cctop-og-render.XXXXXX)"
trap 'rm -rf "$USER_DATA_DIR"' EXIT

echo "Rendering $OG_HTML"
echo "  Using: $CHROME"
echo "  Output: $OG_PNG"

"$CHROME" \
    --headless=new \
    --disable-gpu \
    --hide-scrollbars \
    --window-size=1200,630 \
    --user-data-dir="$USER_DATA_DIR" \
    --screenshot="$OG_PNG" \
    --virtual-time-budget=8000 \
    "file://$OG_HTML" >/dev/null 2>&1 || {
    echo "Error: Chrome headless exited with non-zero status" >&2
    exit 1
}

if [ ! -f "$OG_PNG" ]; then
    echo "Error: render did not produce $OG_PNG" >&2
    exit 1
fi

# Verify dimensions; OG card metadata expects 1200x630.
DIMS=$(python3 -c "
import struct, sys
with open('$OG_PNG','rb') as f:
    f.read(16)
    w, h = struct.unpack('>II', f.read(8))
    print(f'{w}x{h}')
")
if [ "$DIMS" != "1200x630" ]; then
    echo "Error: expected 1200x630, got $DIMS" >&2
    exit 1
fi

SIZE=$(wc -c < "$OG_PNG" | tr -d ' ')
echo "Done. $DIMS, ${SIZE} bytes."
