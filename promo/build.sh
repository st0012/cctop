#!/usr/bin/env bash
# Build one video end-to-end:  ./build.sh <video>   (default: launch)
# Pulls screenshots from the repo's docs/, renders frames headlessly, encodes mp4.
set -euo pipefail
cd "$(dirname "$0")"
VIDEO="${1:-launch}"; PORT="${PORT:-8123}"; SCALE="${SCALE:-2}"; FPS=30; DUR="${DUR:-27.8}"
REPO="$(cd ../.. && pwd)"          # <repo> root; needs <repo>/docs/*.png (relocate-friendly: override REPO=)
OUT="out/$VIDEO"
mkdir -p "$OUT" videos/assets
# stage the screenshots the videos reference (regenerable; gitignored)
cp "$REPO"/docs/menubar-dark.png "$REPO"/docs/menubar-navigate.png \
   "$REPO"/docs/theme-tokyoNight-dark.png "$REPO"/docs/theme-gruvbox-dark.png \
   "$REPO"/docs/theme-nord-light.png "$REPO"/docs/theme-claude-light.png "$REPO"/docs/status-icon.png \
   videos/assets/ 2>/dev/null || true
cp "$REPO"/menubar/CctopMenubar/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png videos/assets/appicon.png 2>/dev/null || true

pkill -f "http.server $PORT" 2>/dev/null || true; sleep 0.3
nohup python3 -m http.server "$PORT" --bind 127.0.0.1 >/tmp/promo-http.log 2>&1 &
sleep 0.6
node engine/render.mjs --url="http://127.0.0.1:$PORT/videos/$VIDEO.html" \
  --out="$OUT/frames" --duration="$DUR" --fps="$FPS" --scale="$SCALE"
bash engine/encode.sh "$OUT/frames" "$OUT/$VIDEO.mp4"
echo "Built $OUT/$VIDEO.mp4  (and ${VIDEO}-720p.mp4)"
