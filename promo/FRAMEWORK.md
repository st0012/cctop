# cctop Promo Video Framework

A small, reproducible system for making cctop's promotional videos — and the hard-won
findings behind it. Pairs with the **`promo-storyboard` skill** (the narrative half) and the
`reference-promo-video-pipeline` memory.

The split it's built around: **story → engine → theme → video**. You change one layer without
touching the others. Recolour the app? Edit `theme.css`. New 15s "for teams" cut? Add a file in
`videos/`. The pipeline and the easing runtime never move.

---

## Layout

```
promo/
├── FRAMEWORK.md          ← this file
├── theme.css             ← design tokens (colours, fonts). EDIT HERE to restyle every video.
├── lib.js                ← shared timeline runtime (easings, rev(), set()). Rarely touched.
├── engine/
│   ├── render.mjs        ← drives headless Chrome over CDP, one screenshot per frame (zero deps)
│   └── encode.sh         ← ffmpeg: frames → 1080p H.264 (+720p), BT.709, no fade-in
├── videos/
│   ├── launch.html       ← the launch promo (~28s). A "video" = one self-contained HTML file.
│   └── assets/           ← staged screenshots (gitignored; copied from <repo>/docs at build time)
├── build.sh              ← one command: ./build.sh <video>
├── .gitignore            ← out/, videos/assets/, *.mp4, frames/
└── out/<video>/          ← rendered frames + mp4 (gitignored, regenerable)
```

A **video** is a single HTML file that:
- links `../theme.css` (colours) and `../lib.js` (helpers),
- lays out its DOM, and
- exposes `window.__seek(t)` — a pure function of time `t` (seconds) that sets every element's
  position/opacity from `t` with **no CSS transitions**. That determinism is the whole trick:
  any frame is reproducible, so the renderer can photograph time `t` exactly, and QA can inspect
  any moment on demand.

---

## Build

```bash
cd promo
./build.sh launch                 # → out/launch/launch.mp4 (+ launch-720p.mp4)
DUR=15 ./build.sh teaser          # a shorter cut; SCALE=1 for a fast preview render
```

`build.sh` stages the screenshots each video references from `<repo>/docs/*.png` into
`videos/assets/`, serves `promo/` over a local http server, renders every frame headlessly at 2×
(supersampled), and encodes. Requires: `node` (v22+ for the stable global `WebSocket`; developed on v26), Google Chrome,
`ffmpeg`, `python3`. ~5–6 min for a 28s 30fps render; frames are deleted by `encode.sh` afterward.

**Iterate fast:** while authoring, render a few keyframes instead of the whole thing —
`node engine/render.mjs --url=http://127.0.0.1:8123/videos/launch.html --out=/tmp/k --times=3.6,9,14 --scale=1`.

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

1. **Story first.** Run the `promo-storyboard` skill (DESIGN mode) to get a positioning line, a
   spine (Before-After-Bridge is the default for tight promos), a beat sheet, and a shot list.
   Don't free-associate scenes — the skill exists because that's where promos live or die.
2. `cp videos/launch.html videos/<angle>.html`. Keep the `<link>`/`<script>` includes and the
   `seek()`/render-readiness scaffolding; replace the **scene content and timeline**.
3. Edit the `TL` object (scene start/end times) and the per-scene `draw*()` functions / DOM.
   Reuse `rev()`, `mix()`, easings from `lib.js`. Source any new screenshots into `videos/assets/`.
4. `DUR=<seconds> ./build.sh <angle>`, then QA it (Recipe 3).

A video's structure (see `launch.html`): a `TL` map of named scenes → `[start,end]`, a `seek(t)`
that dispatches to small `draw*()` functions, each computing its elements from `t`. The launch cut's
arc — Hook → Reveal → Scan → Jump → **Payoff** → Stack → Themes → CTA — is one such composition;
a new angle rearranges/replaces beats.

---

## Recipe 3 — QA a cut (the multi-agent pass)

Stills hide motion problems, so QA off the **encoded** mp4, not the source:

1. `ffmpeg -i out/<v>/<v>.mp4 -vf fps=5 /tmp/sweep/frame_%05d.png` (every 0.2s; `frame_N = (N-1)*0.2s`).
2. Fan out parallel reviewers over **overlapping** time-windows (so each transition sits inside one
   window), + a cold-viewer comprehension pass, + an audit using the `promo-storyboard` skill; a
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
- **Reconstruct UI from source, not memory.** The menubar icon is a **tinted base icon asset** (the
  cctop 2×2-grid logo — accent-tinted when something needs you, top row brighter) + **one rounded bar
  with proportional colour segments** — `MenubarIconRenderer.swift` tints the base `MenubarIcon` asset
  and draws the segmented bar (`drawSegmentedBar`); the grid look + HTML sizing come from the asset and
  the `status-icon-html-ratios` memory, **not** separate squares. cctop is a status-area app: the menubar
  has **no app menu / "File Edit"** — just the Apple logo left, the pill among wifi/battery/clock right.
- **Accuracy over flash in copy.** "Every agent. Every editor." overclaims (cctop supports specific
  tools) → "Works with the stack you've got." The default keyboard shortcut is `⌃⌘N`, not `⌃⌘F`
  (some committed `docs/` screenshots are stale on this).

---

## Assets & repo strategy

Measured this repo: **source** (`theme.css`, `lib.js`, `engine/*`, `videos/*.html`, this doc) is
**~30 KB** — version it in the **main repo**; it belongs with the product and changes with the UI.
The **screenshots** the videos use are already in `<repo>/docs/*.png`, so `build.sh` copies them at
build time rather than duplicating. The **heavy, regenerable** parts — `frames/` (~1 GB/run at 2×) and the
mp4s — are `.gitignore`d.

So **a separate repo isn't needed.** Only consider one if you want to archive many large *finished*
videos long-term — and even then, prefer GitHub Releases / object storage over a git repo for binary
mp4s. The deliverable mp4 (~3.5 MB) can be committed as a release artifact if useful, but never
`frames/`.

---

## See also
- **`promo-storyboard` skill** (`~/.claude/skills/promo-storyboard`) — the narrative process:
  positioning → spine → beats → script → storyboard → review, plus the failure-mode checklist.
- **`reference-promo-video-pipeline` memory** — the pipeline at a glance.
- `how-it-was-made.html` (in the old `.promo-build/`) — a visual making-of of the launch cut.
