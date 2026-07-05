# Video deliverables

Rendered mp4s are **gitignored** (they live in each project's `.video-build/`, regenerable with
`./build.sh <project>`). The *source* is what's versioned. Approved cctop video assets are published
to the non-latest `media-assets` GitHub Release through the repo-local `$video-assets` workflow.

| project | published assets | source commit | notes |
|---------|------------------|---------------|-------|
| launch  | [`preview.avif`](https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch-preview.avif), [`720p.mp4`](https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch-720p.mp4), [`1080p.mp4`](https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch.mp4) | _pending source commit_ | 30s launch video; AVIF is the README inline preview |
| launch social clip | [`clip.mp4`](https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch-clip.mp4), [`clip-720p.mp4`](https://github.com/st0012/cctop/releases/download/media-assets/cctop-launch-clip-720p.mp4) | _pending source commit_ | 12.5s timeline cut of the launch project (see below); for feed posts, release announcements, and replies |

## Social clip (timeline cut)

The social clip is a named cut of the launch project. There is no separate source
file; it renders the same `projects/launch/body.html` over a sub-range of the
timeline:

```bash
CUT=clip ./build.sh launch     # -> .video-build/launch-clip.mp4 (and -720p)
```

The cut's boundaries are defined once, in `projects/launch/body.html` as
`window.__cuts.clip`, right next to the `TL` beat table and derived from it, so
retiming beats moves the cut automatically:

- **In**: end of the morph beat plus a short settle, the first moment the panel is
  fully readable. Earlier frames are mostly empty (hook text fading, dots still
  converging), which reads as a blank first frame in feeds.
- **Out**: end of the payoff beat minus a margin, while it is still fully lit, so
  the encoder's 0.6s fade-out lands on bright content instead of fading a fade.

The build log prints the resolved boundaries (`cut 'clip': t=[...] -> frames ...`);
sanity-check them after any substantial beat or copy change, e.g. by sampling the
boundary frames with `render.mjs --times`.

Upload with the `$video-assets` one-off helper, keeping the stable asset names:

```bash
.agents/skills/video-assets/scripts/upload-video-asset.sh \
  --file video/projects/launch/.video-build/launch-clip.mp4 --name cctop-launch-clip.mp4 --clobber
.agents/skills/video-assets/scripts/upload-video-asset.sh \
  --file video/projects/launch/.video-build/launch-clip-720p.mp4 --name cctop-launch-clip-720p.mp4 --clobber
```

**Keep the clip matching the launch video**: when the launch video is re-rendered
and republished, re-cut the clip from the same checkout and re-upload it too.

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
