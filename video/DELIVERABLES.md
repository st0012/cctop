# Video deliverables

Rendered mp4s are **gitignored** (they live in each project's `.video-build/`, regenerable with
`./build.sh <project>`). The *source* is what's versioned. The approved cut of each video is
published as a **GitHub Release asset**; this file is the durable pointer from a project to its
published mp4 and the commit it was built from.

| project | published asset | source commit | notes |
|---------|-----------------|---------------|-------|
| launch  | _not published yet_ | _pending_ | ~28s launch video (1080p + 720p) |

## Publishing a cut

1. `./build.sh <project>` and get explicit approval on the rendered preview.
2. `gh release create video-<project>-vN projects/<project>/.video-build/<project>.mp4` (and the `-720p`).
3. Record the asset URL + the source commit in the table above. Point the README/site at the
   Release asset, **never** an in-tree binary.

## Archive

The previous (v1) launch video is parked in the gitignored `.video-archive/` at the repo root
(`v1-launch.mp4` + `-720p`, plus the abandoned `vertical-mockup.html` and the v1 `making-of`). Attach v1 to a Release if
it's worth keeping as the historical record; otherwise delete `.video-archive/`.
