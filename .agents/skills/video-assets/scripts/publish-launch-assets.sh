#!/usr/bin/env bash
set -euo pipefail

repo="st0012/cctop"
release_tag="media-assets"
build_dir="video/projects/launch/.video-build"
preview_out=""
avif_width=800
avif_fps=12
avif_crf=38
avif_preset=10
clobber=0
dry_run=0
allow_v_tag=0

usage() {
  cat <<'USAGE'
Usage:
  publish-launch-assets.sh [--clobber] [--dry-run]

Generates the launch README AVIF preview from launch-720p.mp4, then uploads
the standard launch asset set to the media-assets release:
  cctop-launch.mp4
  cctop-launch-720p.mp4
  cctop-launch-preview.avif

Options:
  --build-dir <path>      Build output directory. Defaults to video/projects/launch/.video-build.
  --preview-out <path>    Keep the generated AVIF at this path. Defaults to a temp file.
  --repo <owner/repo>     GitHub repository. Defaults to st0012/cctop.
  --release <tag>         Release tag. Defaults to media-assets.
  --clobber               Replace existing assets with the same names.
  --dry-run               Generate/check assets but do not change GitHub.
  --allow-v-tag           Allow uploading to a v* product release.
  --avif-width <px>       Preview width. Defaults to 800.
  --avif-fps <fps>        Preview frame rate. Defaults to 12.
  --avif-crf <value>      AV1 CRF. Defaults to 38.
  --avif-preset <value>   SVT-AV1 preset. Defaults to 10.
  -h, --help              Show this help.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)
      [[ $# -ge 2 ]] || die "--build-dir requires a value"
      build_dir="$2"
      shift 2
      ;;
    --preview-out)
      [[ $# -ge 2 ]] || die "--preview-out requires a value"
      preview_out="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      repo="$2"
      shift 2
      ;;
    --release)
      [[ $# -ge 2 ]] || die "--release requires a value"
      release_tag="$2"
      shift 2
      ;;
    --clobber)
      clobber=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --allow-v-tag)
      allow_v_tag=1
      shift
      ;;
    --avif-width)
      [[ $# -ge 2 ]] || die "--avif-width requires a value"
      avif_width="$2"
      shift 2
      ;;
    --avif-fps)
      [[ $# -ge 2 ]] || die "--avif-fps requires a value"
      avif_fps="$2"
      shift 2
      ;;
    --avif-crf)
      [[ $# -ge 2 ]] || die "--avif-crf requires a value"
      avif_crf="$2"
      shift 2
      ;;
    --avif-preset)
      [[ $# -ge 2 ]] || die "--avif-preset requires a value"
      avif_preset="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$avif_width" =~ ^[0-9]+$ ]] || die "--avif-width must be an integer"
[[ "$avif_fps" =~ ^[0-9]+$ ]] || die "--avif-fps must be an integer"
[[ "$avif_preset" =~ ^[0-9]+$ ]] || die "--avif-preset must be an integer"
[[ "$avif_crf" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--avif-crf must be numeric"

full_mp4="$build_dir/launch.mp4"
mp4_720="$build_dir/launch-720p.mp4"
[[ -f "$full_mp4" ]] || die "missing full render: $full_mp4"
[[ -f "$mp4_720" ]] || die "missing 720p render: $mp4_720"

command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required to generate the AVIF preview"

tmp_dir=""
if [[ -z "$preview_out" ]]; then
  tmp_dir="$(mktemp -d)"
  preview_out="$tmp_dir/cctop-launch-preview.avif"
fi

cleanup() {
  if [[ -n "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

mkdir -p "$(dirname "$preview_out")"

printf 'Generating AVIF preview: %s\n' "$preview_out"
ffmpeg -y -hide_banner -loglevel error \
  -i "$mp4_720" \
  -vf "fps=${avif_fps},scale=${avif_width}:-2" \
  -c:v libsvtav1 \
  -crf "$avif_crf" \
  -preset "$avif_preset" \
  -an \
  "$preview_out"

ls -lh "$full_mp4" "$mp4_720" "$preview_out"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
upload_script="$script_dir/upload-video-asset.sh"
[[ -x "$upload_script" ]] || die "upload helper is not executable: $upload_script"

upload_args=(--repo "$repo" --release "$release_tag")
if [[ "$clobber" -eq 1 ]]; then
  upload_args+=(--clobber)
fi
if [[ "$dry_run" -eq 1 ]]; then
  upload_args+=(--dry-run)
fi
if [[ "$allow_v_tag" -eq 1 ]]; then
  upload_args+=(--allow-v-tag)
fi

"$upload_script" --file "$full_mp4" --name cctop-launch.mp4 "${upload_args[@]}"
"$upload_script" --file "$mp4_720" --name cctop-launch-720p.mp4 "${upload_args[@]}"
"$upload_script" --file "$preview_out" --name cctop-launch-preview.avif "${upload_args[@]}"

printf 'Launch asset URLs:\n'
printf '  https://github.com/%s/releases/download/%s/cctop-launch-preview.avif\n' "$repo" "$release_tag"
printf '  https://github.com/%s/releases/download/%s/cctop-launch-720p.mp4\n' "$repo" "$release_tag"
printf '  https://github.com/%s/releases/download/%s/cctop-launch.mp4\n' "$repo" "$release_tag"
