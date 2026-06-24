#!/usr/bin/env bash
# Build one video end-to-end:  ./build.sh <project>   (default: launch)
# Renders projects/<project>/body.html headlessly and encodes the mp4. Everything the build
# touches (staged screenshots, frames, mp4, poster) lives in projects/<project>/.video-build/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="${1:-launch}"; PORT="${PORT:-8123}"; SCALE="${SCALE:-2}"; FPS=30; DUR="${DUR:-27.8}"; W="${W:-1920}"; H="${H:-1080}"
REPO="$(cd .. && pwd)"                 # <repo> root: needs <repo>/docs/*.png (relocate-friendly: override REPO=)
PDIR="projects/$PROJECT"
[ -f "$PDIR/body.html" ] || { echo "no such project: $PDIR/body.html"; exit 1; }
BUILD="$PDIR/.video-build"; ASSETS="$BUILD/assets"
mkdir -p "$ASSETS"

# stage the screenshots this project references. No `|| true` — a missing source fails loudly.
# (a per-project assets.txt, one basename per line, overrides the default set)
ASSET_LIST="menubar-dark menubar-navigate theme-tokyoNight-dark theme-gruvbox-dark theme-nord-light theme-claude-light status-icon"
[ -f "$PDIR/assets.txt" ] && ASSET_LIST="$(tr '\n' ' ' < "$PDIR/assets.txt")"
for f in $ASSET_LIST; do cp "$REPO/docs/$f.png" "$ASSETS/$f.png"; done
# the real app icons: the full-colour AppIcon (CTA) and the menubar template logo (the pill grid,
# tinted accent via CSS mask). Trim the template's transparent margin so it fills the grid box.
XCA="$REPO/menubar/CctopMenubar/Assets.xcassets"
cp "$XCA/AppIcon.appiconset/icon_512x512@2x.png" "$ASSETS/appicon.png"
magick "$XCA/MenubarIcon.imageset/menubar-icon@2x.png" -trim +repage "$ASSETS/menubar-icon.png"
# shared tool logos (agents/editors/terminals) for the STACK beat — see assets/icons/README.md
mkdir -p "$ASSETS/icons"; cp "$REPO"/assets/icons/*.svg "$REPO"/assets/icons/*.png "$ASSETS/icons/"

pkill -f "http.server $PORT" 2>/dev/null || true; sleep 0.3
nohup python3 -m http.server "$PORT" --bind 127.0.0.1 >/tmp/cctop-video-http.log 2>&1 &
sleep 0.6
node engine/render.mjs --url="http://127.0.0.1:$PORT/$PDIR/body.html" \
  --out="$BUILD/frames" --duration="$DUR" --fps="$FPS" --scale="$SCALE" --width="$W" --height="$H"
OW="$W" OH="$H" bash engine/encode.sh "$BUILD/frames" "$BUILD/$PROJECT.mp4"
bash engine/check.sh "$BUILD/$PROJECT.mp4" || echo "check.sh reported issues (above)"
echo "Built $BUILD/$PROJECT.mp4  (and ${PROJECT}-720p.mp4)"
