# Video deliverables

Rendered mp4s are **gitignored** (they live in each project's `.video-build/`, regenerable with
`./build.sh <project>`). The *source* is what's versioned. Approved cctop video assets are published
to the non-latest `media-assets` GitHub Release through the repo-local `$video-assets` workflow.

| project | published assets | source commit | notes |
|---------|------------------|---------------|-------|
| launch  | [`preview.avif`](https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch-preview.avif), [`720p.mp4`](https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch-720p.mp4), [`1080p.mp4`](https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch.mp4) | _pending source commit_ | ~28s launch video; AVIF is the README inline preview |

## Publishing a cut

1. `./build.sh <project>` and get explicit approval on the rendered preview.
2. Use `$video-assets`, not ad hoc `gh release create` commands. For the launch cut, dry-run first:

   ```bash
   .agents/skills/video-assets/scripts/publish-launch-assets.sh --clobber --dry-run
   ```

3. Report the release tag, source files, stable asset names, `--clobber` behavior, and resulting URLs.
   Wait for explicit approval unless the latest user message clearly authorizes publishing.
4. Publish:

   ```bash
   .agents/skills/video-assets/scripts/publish-launch-assets.sh --clobber
   ```

5. Record the asset URLs + the source commit in the table above. Point README/site preview images at
   the release-hosted AVIF, and point full video links at the release MP4s. Do not commit rendered
   MP4s or `.video-build/`.

## Archive

The previous (v1) launch video is parked in the gitignored `.video-archive/` at the repo root
(`v1-launch.mp4` + `-720p`, plus the abandoned `vertical-mockup.html` and the v1 `making-of`). Attach v1 to a Release if
it's worth keeping as the historical record; otherwise delete `.video-archive/`.
