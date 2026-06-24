#!/usr/bin/env bash
# Assemble rendered frames into an H.264 video at the target resolution.
# No fade-IN (the first frame must not be black, or paused players show a black poster);
# gentle fade-OUT only. Tagged BT.709 limited-range so QuickTime/Safari render it correctly.
# Output dims default to 1080p landscape; override OW/OH for other aspect ratios (e.g. vertical 1080x1920).
set -euo pipefail
CALLER_PWD="$PWD"
cd "$(dirname "$0")"

FRAMES_DIR="${1:-frames}"
OUT="${2:-out.mp4}"
# build.sh passes paths relative to video/, but we just cd'd into engine/ — resolve against the caller.
case "$FRAMES_DIR" in /*) ;; *) FRAMES_DIR="$CALLER_PWD/$FRAMES_DIR" ;; esac
case "$OUT" in /*) ;; *) OUT="$CALLER_PWD/$OUT" ;; esac
FPS=30
OW="${OW:-1920}"; OH="${OH:-1080}"     # output resolution (frames are supersampled above this)
TAGS=(-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv)

N=$(ls "$FRAMES_DIR"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')
DUR=$(echo "scale=3; $N / $FPS" | bc)
FOUT_ST=$(echo "scale=3; $DUR - 0.6" | bc)
echo "Encoding $N frames (${DUR}s) -> $OUT  (${OW}x${OH})"

ffmpeg -y -hide_banner -loglevel error \
  -framerate "$FPS" -i "$FRAMES_DIR/frame_%05d.png" \
  -vf "scale=${OW}:${OH}:flags=lanczos:out_color_matrix=bt709:out_range=tv,fade=t=out:st=${FOUT_ST}:d=0.6,format=yuv420p,setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709" \
  -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p "${TAGS[@]}" -movflags +faststart -r "$FPS" \
  "$OUT"

# web-optimized smaller variant (2/3 scale, rounded to even dims)
ffmpeg -y -hide_banner -loglevel error -i "$OUT" \
  -vf "scale=trunc(iw/1.5/2)*2:trunc(ih/1.5/2)*2:flags=lanczos,format=yuv420p,setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709" \
  -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p "${TAGS[@]}" \
  -movflags +faststart "${OUT%.mp4}-720p.mp4"

# poster frame: a CTA-region frame near the end (2s before fade-out)
POSTER_N=$(printf "%05d" "$(( N > 60 ? N - 60 : N ))")
cp "$FRAMES_DIR/frame_${POSTER_N}.png" "${OUT%.mp4}-poster.png" 2>/dev/null || true

echo "Done:"
ls -lh "$OUT" "${OUT%.mp4}-720p.mp4" 2>/dev/null | awk '{print "  "$5"  "$9}'

# clean up the heavy intermediate frames (regenerable; deterministic re-render)
rm -rf "$FRAMES_DIR"
