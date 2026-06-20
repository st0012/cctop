#!/usr/bin/env bash
# Assemble rendered frames (3840x2160) into a 1080p H.264 promo.
# No fade-IN (the first frame must not be black, or paused players show a black poster);
# gentle fade-OUT only. Tagged BT.709 limited-range so QuickTime/Safari render it correctly.
set -euo pipefail
cd "$(dirname "$0")"

FRAMES_DIR="${1:-frames}"
OUT="${2:-cctop-promo.mp4}"
FPS=30
TAGS=(-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv)

N=$(ls "$FRAMES_DIR"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')
DUR=$(echo "scale=3; $N / $FPS" | bc)
FOUT_ST=$(echo "scale=3; $DUR - 0.6" | bc)
echo "Encoding $N frames (${DUR}s) -> $OUT"

ffmpeg -y -hide_banner -loglevel error \
  -framerate "$FPS" -i "$FRAMES_DIR/frame_%05d.png" \
  -vf "scale=1920:1080:flags=lanczos:out_color_matrix=bt709:out_range=tv,fade=t=out:st=${FOUT_ST}:d=0.6,format=yuv420p,setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709" \
  -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p "${TAGS[@]}" -movflags +faststart -r "$FPS" \
  "$OUT"

# web-optimized smaller variant
ffmpeg -y -hide_banner -loglevel error -i "$OUT" \
  -vf "scale=1280:720:flags=lanczos,format=yuv420p,setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709" \
  -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p "${TAGS[@]}" \
  -movflags +faststart "${OUT%.mp4}-720p.mp4"

# poster frame (CTA)
cp "$FRAMES_DIR/frame_00705.png" poster.png 2>/dev/null || true

echo "Done:"
ls -lh "$OUT" "${OUT%.mp4}-720p.mp4" 2>/dev/null | awk '{print "  "$5"  "$9}'

# clean up the heavy intermediate frames (regenerable; deterministic re-render)
rm -rf "$FRAMES_DIR"
