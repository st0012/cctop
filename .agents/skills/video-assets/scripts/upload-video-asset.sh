#!/usr/bin/env bash
set -euo pipefail

repo="st0012/cctop"
release_tag="media-assets"
release_title="Media assets"
source_file=""
asset_name=""
clobber=0
dry_run=0
allow_v_tag=0

usage() {
  cat <<'USAGE'
Usage:
  upload-video-asset.sh --file <path> [--name <asset-name>] [--clobber]

Options:
  --file <path>         Source video/image file to upload.
  --name <asset-name>   Release asset filename. Defaults to source basename.
  --release <tag>       Release tag. Defaults to media-assets.
  --title <title>       Title when creating a missing release.
  --repo <owner/repo>   GitHub repository. Defaults to st0012/cctop.
  --clobber             Replace an existing asset with the same name.
  --dry-run             Print what would happen without changing GitHub.
  --allow-v-tag         Allow uploading to a v* product release.
  -h, --help            Show this help.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || die "--file requires a value"
      source_file="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      asset_name="$2"
      shift 2
      ;;
    --release)
      [[ $# -ge 2 ]] || die "--release requires a value"
      release_tag="$2"
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || die "--title requires a value"
      release_title="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      repo="$2"
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$source_file" ]] || die "--file is required"
[[ -f "$source_file" ]] || die "file not found: $source_file"

if [[ -z "$asset_name" ]]; then
  asset_name="$(basename "$source_file")"
fi

[[ "$asset_name" != */* ]] || die "--name must be a filename, not a path"
[[ "$asset_name" != .* ]] || die "--name should not be hidden"

if [[ "$release_tag" == v* && "$allow_v_tag" -ne 1 ]]; then
  die "refusing v* product release tag '$release_tag' without --allow-v-tag"
fi

download_url="https://github.com/${repo}/releases/download/${release_tag}/${asset_name}"

printf 'repo: %s\n' "$repo"
printf 'release: %s\n' "$release_tag"
printf 'source: %s\n' "$source_file"
printf 'asset: %s\n' "$asset_name"
printf 'replace existing: %s\n' "$([[ "$clobber" -eq 1 ]] && echo yes || echo no)"
printf 'download URL: %s\n' "$download_url"

if [[ "$dry_run" -eq 1 ]]; then
  printf 'dry run: no GitHub changes made\n'
  exit 0
fi

command -v gh >/dev/null 2>&1 || die "gh is required"
gh auth status >/dev/null

latest_tag="$(gh release view --repo "$repo" --json tagName --jq '.tagName' 2>/dev/null || true)"
if [[ "$release_tag" == "media-assets" && "$latest_tag" == "$release_tag" ]]; then
  die "media-assets is marked latest; fix the release state before uploading"
fi

if ! gh release view "$release_tag" --repo "$repo" >/dev/null 2>&1; then
  gh release create "$release_tag" \
    --repo "$repo" \
    --title "$release_title" \
    --notes "Shared README and launch video assets for cctop. This release is intentionally not the latest app release." \
    --latest=false
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

staged_file="$tmp_dir/$asset_name"
cp "$source_file" "$staged_file"

args=(release upload "$release_tag" "$staged_file" --repo "$repo")
if [[ "$clobber" -eq 1 ]]; then
  args+=(--clobber)
fi

gh "${args[@]}"
printf 'uploaded: %s\n' "$download_url"
