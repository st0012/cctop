---
name: video-assets
description: Use when publishing, replacing, auditing, or linking cctop promo/demo video assets through GitHub Releases, especially the non-latest media-assets release. Trigger for requests like "upload the launch video", "add another video asset", "replace the README demo video", "where should this video live", "update media-assets", or "generate the README AVIF preview". Covers stable asset names, release selection, AVIF preview generation, README/site links, and avoiding v* product-release tags. Do not use for video narrative/storyboard work; use video-storyboard for that.
---

# Video Assets

Manage cctop video files as GitHub Release assets, not as committed repo binaries. The default pattern is one non-latest media release that acts as a stable asset bucket.

## Rules

- Default release tag: `media-assets`.
- Default release title: `Media assets`.
- Always create media-only releases with `--latest=false`.
- Do not use a `v*` tag for media-only work. In cctop, `v*` tags trigger `.github/workflows/release.yml`: app builds, notarization, GitHub Release creation, Sparkle appcast, and Homebrew updates.
- Attach a video to a real `v*` release only when the user explicitly asks and the video truthfully demonstrates that shipped app version.
- Keep full MP4s and other large rendered video out of git. Do not commit `video/projects/*/.video-build/`.
- Commit a small animated README preview only when the user explicitly chooses that route and the file is intentionally small.
- Prefer stable purpose-based asset names over dates: `cctop-launch.mp4`, `cctop-launch-720p.mp4`, `cctop-launch-preview.avif`.
- For launch video uploads, always generate and upload the AVIF preview alongside the MP4s so the README preview and full video stay in sync.

## Workflow

1. Identify the source files.
   - Launch defaults: `video/projects/launch/.video-build/launch.mp4` and `video/projects/launch/.video-build/launch-720p.mp4`.
   - Check existence and size with `ls -lh`.
   - Check duration/codec with `ffprobe` when available.

2. Pick the release target.
   - Use `media-assets` for reusable README/demo/launch assets.
   - Use an existing app release such as `v0.18.4` only with explicit user direction.
   - Inspect before mutating: `gh release view media-assets --repo st0012/cctop`.

3. Pick stable asset names.
   - Reusing the same asset name plus `--clobber` keeps the download URL stable.
   - Use a new asset name when history matters or two variants should coexist.
   - Remember: `gh release upload file.mp4#Label` sets a display label, not a stable download filename. Stage or copy the file to the intended asset filename before upload.
   - Default launch asset set:
     - `cctop-launch.mp4` from `launch.mp4`
     - `cctop-launch-720p.mp4` from `launch-720p.mp4`
     - `cctop-launch-preview.avif` generated from `launch-720p.mp4`

4. Gate public mutations.
   - Before creating a release, uploading, or replacing assets, state: release tag, source file, asset name, whether `--clobber` will be used, and the resulting download URL.
   - Wait for explicit approval unless the user's latest request already clearly authorizes the upload/update.
   - Never publish a media release as latest.

5. Publish launch assets with the wrapper script. This is the default path for launch renders.

```bash
.agents/skills/video-assets/scripts/publish-launch-assets.sh --clobber
```

Use `--dry-run` first when checking paths or explaining what will happen:

```bash
.agents/skills/video-assets/scripts/publish-launch-assets.sh --clobber --dry-run
```

The wrapper:
- Verifies both MP4s exist.
- Generates a fresh animated AVIF preview from the 720p MP4 with `ffmpeg`.
- Uploads all three assets to `media-assets`.
- Keeps the stable download URLs unchanged by reusing the same asset names.

6. Upload individual assets only for non-launch one-offs.

```bash
.agents/skills/video-assets/scripts/upload-video-asset.sh \
  --file video/projects/launch/.video-build/launch.mp4 \
  --name cctop-launch.mp4 \
  --clobber
```

For another video:

```bash
.agents/skills/video-assets/scripts/upload-video-asset.sh \
  --file path/to/other-video.mp4 \
  --name cctop-other-video.mp4
```

The stable download URL shape is:

```text
https://github.com/st0012/cctop/releases/download/media-assets/<asset-name>
```

Launch URLs:

```text
https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch-preview.avif
https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch-720p.mp4
https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch.mp4
```

## README/Site Links

- For an inline README animation, prefer the release-hosted AVIF preview and an `<img>` tag.
- Use `cctop-launch-preview.avif` from the same `media-assets` release as the MP4s unless the user explicitly wants a committed preview file.
- For the full video, link to the release asset URL.
- Avoid `releases/latest/download/...` for media assets unless every future product release will carry the same asset name. cctop's README and site already use `releases/latest` for app downloads, so media assets should stay separate.

## Helper

`scripts/publish-launch-assets.sh` is the preferred launcher for cctop launch renders. It creates a fresh AVIF preview and delegates uploads to `scripts/upload-video-asset.sh`.

`scripts/upload-video-asset.sh` creates `media-assets` if needed with `--latest=false`, stages the file under the intended asset filename, then uploads it. It refuses `v*` tags unless passed `--allow-v-tag`.
