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

if ! command -v magick >/dev/null 2>&1; then
    echo "Error: ImageMagick required (brew install imagemagick)" >&2
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

# Chrome --headless=new on macOS reserves ~88px of vertical space for invisible
# window chrome — content positioned below ~y=542 in a 1200x630 window simply
# doesn't render. Workaround: render into a taller window so the layout viewport
# is at least 630 tall, then top-crop the screenshot to the OG-required 1200x630.
RENDER_PNG="$USER_DATA_DIR/render.png"
CHROME_LOG="$USER_DATA_DIR/chrome.log"
"$CHROME" \
    --headless=new \
    --disable-gpu \
    --hide-scrollbars \
    --window-size=1200,800 \
    --user-data-dir="$USER_DATA_DIR" \
    --screenshot="$RENDER_PNG" \
    --virtual-time-budget=8000 \
    "file://$OG_HTML" >/dev/null 2>"$CHROME_LOG" || {
    echo "Error: Chrome headless exited with non-zero status" >&2
    sed 's/^/  chrome: /' "$CHROME_LOG" >&2
    exit 1
}

magick "$RENDER_PNG" -crop 1200x630+0+0 +repage "$OG_PNG" >/dev/null 2>&1 || {
    echo "Error: ImageMagick crop failed" >&2
    exit 1
}

DIMS=$(magick identify -format '%wx%h' "$OG_PNG")
if [ "$DIMS" != "1200x630" ]; then
    echo "Error: expected 1200x630, got $DIMS" >&2
    exit 1
fi

SIZE=$(wc -c < "$OG_PNG" | tr -d ' ')
echo "Done. $DIMS, ${SIZE} bytes."
