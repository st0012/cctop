# cctop Video Framework

A small, reproducible system for making cctop's videos — and the hard-won findings behind it.
Pairs with the **video-storyboard skill** (the narrative half), the **video-assets skill**
(release publishing), and the video-pipeline memory.

The split it's built around: **story → engine → theme → video**. You change one layer without
touching the others. Recolour the app? Edit `theme.css`. New 15s "for teams" cut? Add a project
under `projects/`. The pipeline and the easing runtime never move.

---

## Layout

```
video/
├── framework.md          ← this file
├── theme.css             ← design tokens (colours, fonts). EDIT HERE to restyle every video.
├── lib.js                ← shared timeline runtime (easings, rev(), set(), whenReady()). Rarely touched.
├── engine/
│   ├── render.mjs        ← drives headless Chrome over CDP, one screenshot per frame (zero deps)
│   ├── encode.sh         ← ffmpeg: frames → 1080p H.264 (+720p), BT.709, no fade-in
│   └── check.sh          ← mechanical asserts on the mp4 (frame0≠black, BT.709 tags, 720p present)
├── projects/             ← one folder per video — EVERYTHING for that video lives here
│   └── launch/
│       ├── body.html         ← the cut (~28s). A "video" = one self-contained HTML file.
│       ├── storyboard.html   ← static key-frame design reference
│       ├── jump-editor.html  ← project tool (NOT rendered — build only targets body.html)
│       └── .video-build/     ← [gitignored] staged screenshots, frames, mp4, 720p, poster, qa
├── build.sh              ← one command: ./build.sh <project>
├── DELIVERABLES.md       ← project → published Release asset → source commit
└── .gitignore            ← .video-build/, *.mp4
```

A **video** is a single `projects/<name>/body.html` that:
- links `../../theme.css` (colours) and `../../lib.js` (helpers, incl. `whenReady`),
- lays out its DOM, and
- exposes `window.__seek(t)` — a pure function of time `t` (seconds) that sets every element's
  position/opacity from `t` with **no CSS transitions**. That determinism is the whole trick:
  any frame is reproducible, so the renderer can photograph time `t` exactly, and QA can inspect
  any moment on demand.

---

## Build

```bash
cd video
./build.sh launch                 # → projects/launch/.video-build/launch.mp4 (+ -720p), then runs check.sh
DUR=15 ./build.sh teaser          # a shorter cut; SCALE=1 for a fast preview render
```

`build.sh` stages the screenshots each project references from `<repo>/docs/*.png` into
`projects/<name>/.video-build/assets/`, serves `video/` over a local http server, renders every frame
headlessly at 2× (supersampled), encodes, then runs `engine/check.sh` on the result. Requires: `node`
(v22+ for the stable global `WebSocket`; developed on v26), Google Chrome, `ffmpeg`, `python3`, ImageMagick.
~5–6 min for a 28s 30fps render; frames are deleted by `encode.sh` afterward.

**Iterate fast:** while authoring, render a few keyframes instead of the whole thing —
`node engine/render.mjs --url=http://127.0.0.1:8123/projects/launch/body.html --out=/tmp/k --times=3.6,9,14 --scale=1`.

## Publish

Publishing is intentionally separate from rendering. First render and get explicit approval on the
preview. Then use the repo-local **video-assets skill** so the README preview and full videos stay in
sync.

From the repo root, dry-run the standard launch asset set:

```bash
.agents/skills/video-assets/scripts/publish-launch-assets.sh --clobber --dry-run
```

Report the release tag, source files, stable asset names, and resulting URLs, then wait for explicit
approval unless the latest user message clearly authorizes publishing. The real upload is:

```bash
.agents/skills/video-assets/scripts/publish-launch-assets.sh --clobber
```

That regenerates `cctop-launch-preview.avif` from `launch-720p.mp4`, then uploads:

- `cctop-launch-preview.avif`
- `cctop-launch-720p.mp4`
- `cctop-launch.mp4`

All three live on the non-latest `media-assets` GitHub Release. Do not create `v*` media-only
releases, and do not commit `.video-build/` outputs.

---

## Recipe 1 — restyle after a colour change

This is a config edit, not a code change.

1. Edit the tokens in **`theme.css`** (e.g. the app shipped a new accent, or you want the
   Gruvbox palette). Keep the status colours (`--accent/--red/--orange/--green`) matching the app.
2. `./build.sh launch` — re-renders with the new look. Nothing else changes.

Because every video links the same `theme.css`, one edit re-skins all of them. If you keep
multiple palettes, copy `theme.css` to `themes/<name>.css` and point a video's `<link>` at it.

---

## Recipe 2 — a new video for a different angle

1. **Story first.** Run the video-storyboard skill (DESIGN mode) to get a positioning line, a
   spine (Before-After-Bridge is the default for tight cuts), a beat sheet, and a shot list.
   Don't free-associate scenes — the skill exists because that's where these videos live or die.
2. `cp -r projects/launch projects/<angle>`, then in `body.html` keep the `<link>`/`<script>` includes
   and the `whenReady(seek)` boot, and replace the **scene content and timeline**.
3. Edit the `TL` object (scene start/end times) and the per-scene `draw*()` functions / DOM.
   Reuse `rev()`, `mix()`, easings (and `whenReady`) from `lib.js`. Put any new screenshots in `<repo>/docs/` and the project's asset list.
4. `DUR=<seconds> ./build.sh <angle>`, then QA it (Recipe 3). If the user approves the cut for
   publishing, use the video-assets publishing workflow above rather than uploading one-off files.

A video's structure (see `projects/launch/body.html`): a `TL` map of named scenes → `[start,end]`, a `seek(t)`
that dispatches to small `draw*()` functions, each computing its elements from `t`. The launch cut's
arc — Hook → Reveal → Scan → Jump → **Payoff** → Stack → Themes → CTA — is one such composition;
a new angle rearranges/replaces beats.

---

## Recipe 3 — QA a cut (the multi-agent pass)

Stills hide motion problems, so QA off the **encoded** mp4, not the source:

1. `ffmpeg -i projects/<p>/.video-build/<p>.mp4 -vf fps=5 /tmp/sweep/frame_%05d.png` (every 0.2s; `frame_N = (N-1)*0.2s`).
2. Fan out parallel reviewers over **overlapping** time-windows (so each transition sits inside one
   window), + a cold-viewer comprehension pass, + an audit using the video-storyboard skill; a
   synthesizer merges into a deduped fix list. (This repo's sessions used the `Workflow` tool for it.)
3. Apply fixes to the video HTML, re-render, repeat. A transient API overload can kill a whole
   workflow run — fall back to a hand pass over the same frames.

What QA reliably catches here: transition overlaps/ghosting, a hook whose visuals contradict its
words, an action with no payoff, a reveal at the wrong altitude, a saggy feature-montage tail.

---

## Gotchas (the expensive lessons — read before debugging)

**Rendering / encoding**
- **"Plays all black in QuickTime"** has two causes, both real: (1) untagged H.264 — tag it
  `-color_primaries/-color_trc/-colorspace bt709 -color_range tv` (already in `encode.sh`); (2) a
  fade-from-black open makes frame 0 literally black, and QuickTime opens *paused on it*. So there's
  **no ffmpeg fade-in**, and the first scene's headline is present on frame 0.
- **Determinism is non-negotiable.** All motion is computed from `t`; no CSS transitions/animations.
  `Date.now()/Math.random()` would break reproducibility — vary by element index instead.
- **Supersample.** Render at `--scale 2` (3840×2160) and let ffmpeg lanczos-downscale to 1080p; text
  is much crisper. Frames are big (~1GB) — `encode.sh` deletes them after encoding (watch disk).

**Motion design**
- **Don't cross-dissolve two different screenshots** (e.g. the plain panel vs the navigate panel —
  their titles truncate differently → doubled/ghosted text). **Hard-cut** instead.
- **Don't slide one highlight ring between two stacked cards** — it straddles the divider and bisects
  a title. **Crossfade two fixed rings**, each wrapping exactly one card.
- **Two centred text scenes can't simply cross-dissolve** — the headlines overlap mid-fade. Clear one
  before the next enters, bridged by a non-conflicting element (e.g. a kicker at a different `y`).
- **Land moving elements before the thing they become paints.** The hook-dots→menubar-pill morph
  showed a "blob below + half-pill above" until the dots landed *at* the pill and the bar arrived
  already-coloured.
- **Offset adjacent scene fades by ~0.1–0.2s** (or dip to near-black) so outgoing text fully clears
  before incoming text becomes legible.

**Fidelity to the real app**
- **Measure, don't guess.** Highlight rects were dialed in by laying a coordinate grid over the real
  screenshot (ImageMagick `-draw` lines; gridline-counting since ghostscript/text isn't installed).
- **Adopt the real icon assets, don't approximate them.** The menubar pill uses the cctop
  `MenubarIcon` template (the 2×2-grid logo) accent-tinted via a CSS `mask` — `build.sh` stages it
  (trimmed) from `menubar/CctopMenubar/Assets.xcassets/`, so if the logo changes the video follows.
  Beside it, **one rounded bar with proportional colour segments** is drawn in DOM. This mirrors the app:
  `MenubarIconRenderer.swift` tints the same `MenubarIcon` asset + `drawSegmentedBar`. The CTA uses the
  real `AppIcon` (full-colour). cctop is a status-area app: the menubar has **no app menu / "File Edit"** —
  just the Apple logo left, the pill among wifi/battery/clock right.
- **Accuracy over flash in copy.** "Every agent. Every editor." overclaims (cctop supports specific
  tools) → "Works with the stack you've got." The default keyboard shortcut is `⌃⌘N`, not `⌃⌘F`
  (some committed `docs/` screenshots are stale on this).

**Overlays / annotations on screenshots (the "still not centered" trap — cost ~6 rounds once)**
- **Measure, don't eyeball; verify before saying "fixed."** Isolate the target's colour and take its
  centroid, then assert the overlay's centre matches within ~1px:
  `magick frame.png -crop WxH+X+Y +repage t.png && magick t.png -fuzz 8% -fill white -opaque 'srgb(R,G,B)' -fuzz 0 -fill black +opaque white -trim -format '%wx%h+%X+%Y' info:`
  (bbox centre = target centre). A crop that "looks centred" is not verification.
- **Put the overlay in the same coordinate space you measured in — canvas/frame-absolute.** Do NOT
  nest it inside a container that has a border/padding/transform/scale: `.panel`'s 1px border shifted
  the child's origin ~1px — invisible to the math, glaring against a tight gap.
- **Leave a generous, even gap (~7–10px).** A ring hugging its target makes a 1px error obvious; a
  roomy halo reads as deliberately centred and is immune to sub-pixel wobble.
- **Cache-bust deliverables.** Reusing the same output filename makes corrected renders look unchanged
  (browser cache). Ship each review iteration under a fresh filename.
- **Contested placement → hand over direct control.** When the user keeps rejecting a placement, a
  tiny drag-to-position editor that outputs exact canvas-coord CSS (see `projects/launch/jump-editor.html`)
  resolves it in one step instead of N nudges.

---

## Assets & repo strategy

Measured this repo: **source** (`theme.css`, `lib.js`, `engine/*`, `projects/*/*.html`, this doc) is
**~30 KB** — version it in the **main repo**; it belongs with the product and changes with the UI.
The **screenshots** the videos use are already in `<repo>/docs/*.png`, so `build.sh` copies them at
build time rather than duplicating. The **heavy, regenerable** parts — `frames/` (~1 GB/run at 2×) and the
mp4s — are `.gitignore`d.

So **a separate repo isn't needed.** Keep finished binaries on GitHub Releases / object storage, not
in git. For the launch cut, the canonical release bucket is `media-assets`, with stable asset names
managed by `$video-assets`.

---

## See also
- **the video-storyboard skill** — the narrative process: positioning → spine → beats → script →
  storyboard → review, plus the failure-mode checklist.
- **the video-assets skill** — the release asset process: generate the AVIF preview, upload the MP4s
  and AVIF together, and keep README links stable.
- **the video-pipeline memory** — the pipeline at a glance.
- the v1 making-of is parked in the gitignored `.video-archive/` (it documents the superseded pipeline).
