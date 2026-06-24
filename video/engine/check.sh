#!/usr/bin/env bash
# Mechanical, deterministic checks on an encoded video. Exits nonzero on any failure.
# Asserts the lessons that are cheap to verify and expensive to miss — so they fail a build
# instead of surviving as prose: frame 0 isn't black, and the stream carries BT.709 tags.
set -uo pipefail
MP4="${1:?usage: check.sh <mp4>}"
[ -f "$MP4" ] || { echo "✗ no mp4 at $MP4"; exit 1; }
fail=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fail=1; }
echo "check: $MP4"

# 1. decodes + has a video stream
dur=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 "$MP4" 2>/dev/null || true)
[ -n "$dur" ] && ok "decodes (${dur}s)" || bad "ffprobe could not read a video stream"

# 2. BT.709 tags — untagged H.264 renders all-black in QuickTime/Safari
read -r prim trc spc < <(ffprobe -v error -select_streams v:0 \
  -show_entries stream=color_primaries,color_transfer,color_space -of csv=p=0 "$MP4" 2>/dev/null | tr ',' ' ')
if [ "${prim:-}" = bt709 ] && [ "${trc:-}" = bt709 ] && [ "${spc:-}" = bt709 ]; then
  ok "BT.709 tags (primaries/transfer/space)"
else bad "missing BT.709 tags (got ${prim:-?}/${trc:-?}/${spc:-?}) — would play all-black in QuickTime"; fi

# 3. frame 0 not black — paused players show frame 0 as the poster
tmp=$(mktemp -d); ffmpeg -y -loglevel error -i "$MP4" -vframes 1 "$tmp/f0.png" 2>/dev/null
mean=$(magick "$tmp/f0.png" -colorspace Gray -format "%[fx:mean*255]" info: 2>/dev/null || echo 0)
awk "BEGIN{exit !($mean>6)}" && ok "frame 0 not black (mean gray ${mean})" || bad "frame 0 is ~black (mean gray ${mean})"
rm -rf "$tmp"

# 4. 720p sibling present
sib="${MP4%.mp4}-720p.mp4"; [ -f "$sib" ] && ok "720p variant present" || bad "no 720p variant"

# Per-project VISUAL asserts (overlay centroid ≈ its target within ~1px; no <img>-backed panel
# rendered transparent) are video-specific — a project can add a check.<project>.sh that extends this.
[ "$fail" = 0 ] && echo "PASS — mechanical checks green" || echo "FAIL — fix the above before shipping"
exit "$fail"
