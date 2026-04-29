# DESIGN.md

Single source of truth for cctop's visual language. Both the macOS menubar
app (`menubar/`) and the marketing site at [cctop.app](https://cctop.app)
(`site/`) implement what's specified here. When a value here drifts from the
implementation, the implementation is wrong.

This document follows the
[Stitch DESIGN.md format](https://github.com/VoltAgent/awesome-design-md) —
nine sections covering theme, color, type, components, layout, elevation,
guardrails, responsive behavior, and an agent quick reference.

---

## 1. Visual Theme & Atmosphere

**Personality.** Calm, precise, utilitarian. cctop is a well-made instrument —
no fuss, just works. The craft shows in details: neutral palette, considered
spacing, keyboard-first interactions. It should feel like a quality indie Mac
app, not a generic system utility.

**Context of use.** Developers monitor multiple AI coding sessions in their
peripheral vision while doing other work. The job is to know which sessions
need action, jump to them fast, and get back to work. Status must be
understood in **under a second**.

**Mood.** Understated and neutral. A themed accent provides identity without
being loud. Neutral grays for text hierarchy — never warm- or cool-tinted.
Dark mode is the primary context (developers); light mode is equally
considered, not an afterthought.

**Density.** Utilitarian density with breathing room. Dense but not cramped.
Every element justifies its space; no decorative chrome, no padding for
padding's sake.

**References.**

- **Linear** — fast, keyboard-first, opinionated.
- **Things 3, Bear** — indie Mac warmth, understated elegance, attention to
  detail.

**Anti-references.**

- Electron-feeling apps with web-like UI.
- Overly branded dashboards.
- Anything that looks like a monitoring tool from an ops context (Grafana,
  Datadog).
- Generic system preferences.

**Surface contexts.**

| Surface         | Theme               | Atmosphere                                                  |
|-----------------|---------------------|-------------------------------------------------------------|
| Menubar app     | Themed (4 palettes) | Quiet glance-tool that lives next to the clock              |
| Notch pill      | Always black        | OS-level chrome — blends with the camera notch              |
| Marketing site  | Tokyo Night dark    | Editor-feeling page — same mood as the menubar in dark mode |

## 2. Color Palette & Roles

cctop ships **four named palettes** — each with explicit dark and light
variants. The Swift app exposes them via the semantic token API in
`menubar/CctopMenubar/Models/Color+Theme.swift`; the site mirrors the
**Tokyo Night dark** palette via CSS custom properties in `site/index.html`.

### Semantic roles

| Role               | Token                                                      | Meaning                                          |
|--------------------|------------------------------------------------------------|--------------------------------------------------|
| Brand accent       | `accent` / `--accent`                                      | Themed identity color (per-palette)              |
| Permission         | `statusPermission`                                         | Urgent — needs approval (red family)             |
| Attention          | `statusAttention`                                          | Waiting for user input (orange family)           |
| Working            | `statusGreen`                                              | Tool is running (green family)                   |
| Idle               | `statusIdle`                                               | Quiet / dimmed (muted family)                    |
| Compacting         | (reuses `agentBadge`)                                      | Context compaction in progress (purple family)   |
| Subagent badge     | `agentBadge`                                               | Active subagent count (purple family)            |
| Source: opencode   | `opencodeBadge`                                            | Blue family across themes                        |
| Source: pi         | `piBadge`                                                  | Teal family across themes                        |
| Source: codex      | `codexBadge`                                               | Gold/bronze family across themes                 |
| Primary text       | `textPrimary`                                              | Project names, header titles                     |
| Secondary text     | `textSecondary`                                            | Branch, meta, "Working" status label             |
| Muted text         | `textMuted`                                                | Timestamps, idle status, footer                  |
| Dimmed text        | `textDimmed`                                               | Idle project names                               |
| Panel background   | `panelBackground` / `--bg`                                 | Main popup panel surface                         |
| Card background    | `cardBackground`                                           | Selected card / settings rows (white@4% / black@2%) |
| Card border        | `cardBorder`                                               | Hairline divider (white@4% / black@4%)           |

**Forward-compatible decoding.** `SessionStatus.init(from:)` first tries to
match the raw string against a known case, then falls back by name: unknown
values containing `"waiting"` map to `.needsAttention`; everything else maps
to `.working`. New server-side status values never crash old clients — but
when adding a backend status, name it `waiting_*` if it should surface as
attention on older builds; otherwise older clients will render it as a
working session.

### Palette: Claude

| Role               | Dark      | Light     |
|--------------------|-----------|-----------|
| accent             | `#D97757` | `#D97757` |
| statusPermission   | `#DD5353` | `#DD5353` |
| statusAttention    | `#D97757` | `#D97757` |
| statusGreen        | `#7EAA6E` | `#4A8238` |
| textPrimary        | `#E8E6DC` | `#141413` |
| textSecondary      | `#C4C2B9` | `#30302E` |
| textMuted          | `#87867F` | `#87867F` |
| textDimmed         | `#87867F` | `#87867F` |
| panelBackground    | `#262624` | `#E8E6DC` |
| statusIdle         | `#87867F` | `#87867F` |
| agentBadge         | `#A256C8` | `#7A3580` |
| opencodeBadge      | `#5C8AB8` | `#2D5A82` |
| piBadge            | `#6EAEA8` | `#346B66` |
| codexBadge         | `#D4A84A` | `#8B6914` |

### Palette: Tokyo Night _(default; mirrored on cctop.app)_

| Role               | Dark      | Light     |
|--------------------|-----------|-----------|
| accent             | `#F7768E` | `#2959AA` |
| statusPermission   | `#F7768E` | `#8C4351` |
| statusAttention    | `#FF9E64` | `#965027` |
| statusGreen        | `#9ECE6A` | `#33635C` |
| textPrimary        | `#C0CAF5` | `#343B59` |
| textSecondary      | `#787C99` | `#363C4D` |
| textMuted          | `#636A85` | `#707280` |
| textDimmed         | `#565D78` | `#888B94` |
| panelBackground    | `#1A1B26` | `#E6E7ED` |
| statusIdle         | `#565D78` | `#707280` |
| agentBadge         | `#BB9AF7` | `#7B43BA` |
| opencodeBadge      | `#7AA2F7` | `#3A5BA0` |
| piBadge            | `#5DBFB1` | `#1F6B5D` |
| codexBadge         | `#E0AF68` | `#7B5A1F` |

### Palette: Gruvbox

| Role               | Dark      | Light     |
|--------------------|-----------|-----------|
| accent             | `#FE8019` | `#AF3A03` |
| statusPermission   | `#FB4934` | `#9D0006` |
| statusAttention    | `#FABD2F` | `#B57614` |
| statusGreen        | `#B8BB26` | `#427B58` |
| textPrimary        | `#EBDBB2` | `#3C3836` |
| textSecondary      | `#A89984` | `#504945` |
| textMuted          | `#7C6F64` | `#7C6F64` |
| textDimmed         | `#928374` | `#928374` |
| panelBackground    | `#282828` | `#FBF1C7` |
| statusIdle         | `#665C54` | `#928374` |
| agentBadge         | `#D3869B` | `#8F3F71` |
| opencodeBadge      | `#83A598` | `#076678` |
| piBadge            | `#8EC07C` | `#427B58` |
| codexBadge         | `#C58940` | `#7A4F0E` |

### Palette: Nord

| Role               | Dark      | Light     |
|--------------------|-----------|-----------|
| accent             | `#BF616A` | `#BF616A` |
| statusPermission   | `#BF616A` | `#BF616A` |
| statusAttention    | `#D08770` | `#D08770` |
| statusGreen        | `#A3BE8C` | `#4E7A35` |
| textPrimary        | `#ECEFF4` | `#2E3440` |
| textSecondary      | `#D8DEE9` | `#3B4252` |
| textMuted          | `#616E88` | `#4C566A` |
| textDimmed         | `#596478` | `#4C566A` |
| panelBackground    | `#2E3440` | `#ECEFF4` |
| statusIdle         | `#596478` | `#4C566A` |
| agentBadge         | `#B48EAD` | `#8B6A86` |
| opencodeBadge      | `#81A1C1` | `#5E81AC` |
| piBadge            | `#8FBCBB` | `#4C7271` |
| codexBadge         | `#EBCB8B` | `#8B6914` |

### Web tokens (cctop.app — Tokyo Night dark only)

The site is single-theme. CSS custom properties live in
`site/index.html` `:root`:

```css
--bg:        #1a1b26;     /* panelBackground */
--bg-2:      #16161e;     /* sunk surface (badges, brew row) */
--surface:   #24283b;     /* canonical Tokyo Night surface */
--surface-2: #2f3549;     /* raised surface */
--line:        rgba(192, 202, 245, 0.10);
--line-strong: rgba(192, 202, 245, 0.18);
--fg:        #c0caf5;     /* textPrimary */
--fg-mute:   #9aa5ce;     /* WCAG-AA-bumped textSecondary for prose */
--fg-dim:    #858eaf;     /* WCAG-AA-bumped textMuted for prose */
--idle-seg:  #565d78;     /* hp-idle bar segment */
--accent:    #ff9e64;     /* attentions.tokyoNight.dark (web hero) */
--danger:    #f7768e;     /* statusPermission */
--status-ok: #9ece6a;     /* statusGreen */
```

**Why `--fg-mute` and `--fg-dim` differ from the app.** The marketing site
runs long-form prose at 11–13 px. The app's exact `#787c99` / `#565D78`
secondary tokens land at ~4.1:1 / 2.6:1 contrast on `--bg`, failing
WCAG AA. The site values bump these to ~6:1 and ~5.4:1 while staying in
the Tokyo Night blue family.

### Shared (theme-independent) tokens

| Role                | Dark               | Light              |
|---------------------|--------------------|--------------------|
| `cardBackground`    | white @ 4% alpha   | black @ 2% alpha   |
| `cardBorder`        | white @ 4% alpha   | black @ 4% alpha   |
| `segmentBackground` | white @ 6% alpha   | black @ 4% alpha   |

## 3. Typography Rules

### Font stacks

| Surface | Sans                                          | Mono                                                      | Serif accent           |
|---------|-----------------------------------------------|-----------------------------------------------------------|------------------------|
| App     | San Francisco (`.system`)                     | SF Mono via `.system(design: .monospaced)`                | _none_                 |
| Site    | `'IBM Plex Sans', -apple-system, system-ui`   | `'IBM Plex Mono', ui-monospace, SFMono-Regular, Menlo`    | `'Instrument Serif'`   |

Site enables OpenType features `ss01` and `cv11` on the body for the alternate
single-storey `a` and a friendlier `g` — the only hint of brand voice in the
type itself. The hero italic uses Instrument Serif for `<em>` only; never as
body type, and never used in the app.

### App type ladder

| Size · Weight     | Usage                                                                |
|-------------------|----------------------------------------------------------------------|
| 13 · semibold     | Header title ("cctop")                                               |
| 13 · medium       | Project name in session card                                         |
| 12                | Empty-state copy, install banner body                                |
| 11                | Settings labels, session context line                                |
| 11 · medium mono  | Shortcut badge ("⇧⌘N")                                               |
| 10                | Subagent badge, branch (mono), timestamp, hint text                  |
| 10 · medium       | Status label ("Working" / "Permission" / "Waiting")                  |
| 10 · medium       | Segmented picker labels                                              |
| 9                 | Source badge ("opencode", "pi", "codex")                             |

The 9 / 10 / 11 / 12 / 13 ladder is intentionally narrow. A panel that's
~320 px wide can't afford a 7-step type scale; restraint is the point.

### Site type ladder

CSS custom properties in `site/index.html` `:root`:

| Token       | Value                            | Usage                                  |
|-------------|----------------------------------|----------------------------------------|
| `--fs-xs`   | `0.75rem` (12 px)                | Eyebrows, captions, copy button        |
| `--fs-sm`   | `0.875rem` (14 px)               | Nav links, pill buttons                |
| `--fs-base` | `1rem` (16 px)                   | Body                                   |
| `--fs-md`   | `1.125rem` (18 px)               | Hero subtitle, section sub-copy        |
| `--fs-lg`   | `1.375rem` (22 px)               | Feature `h3`                           |
| `--fs-xl`   | `1.75rem` (28 px)                | _reserved_                             |
| `--fs-2xl`  | `2.25rem` (36 px)                | `h2` mobile                            |
| `--fs-3xl`  | `clamp(2.5rem, 4vw, 3.25rem)`    | `h2` desktop                           |
| `--fs-4xl`  | `clamp(3rem, 6vw, 4.5rem)`       | _reserved_                             |
| (hero)      | `clamp(2.75rem, 8vw, 7rem)`      | Hero `h1` (44 → 112 px fluid)          |

### Headline rules

- Hero `h1`: line-height `0.96`, letter-spacing `-0.045em`, weight `700`,
  `text-wrap: balance`, capped at `16ch`.
- Section `h2`: weight `600`, line-height `1.1`, letter-spacing `-0.025em`,
  capped at `22ch`.
- Body / sub-copy: line-height `1.55`–`1.65`, capped at `50–70ch` for legibility.

### Color × text pairing

Status meaning is **always** carried by both color and text — never color
alone. The "Working" label is gray, not green; only the proportional bar
and accent stripe carry the green. This keeps the panel readable when you
glance at it from peripheral vision.

## 4. Component Stylings

### Session card (`SessionCardView.swift`)

Three columns: accent bar · content · status/time.

| Property           | Value                                                          |
|--------------------|----------------------------------------------------------------|
| Padding            | 8 px horizontal · 9 px vertical                                |
| Accent bar (default)| 3 px wide, 1.5 px radius, opacity by status (1.0 / 0.4 / 0.1)|
| Accent bar (navigate mode) | 16×16 status-colored square, radius 2 px, white digit |
| Project name       | 13 px medium · `textPrimary` (or `textDimmed` if idle)         |
| Subagent count     | 10 px · `agentBadge` (purple)                                  |
| Source badge       | 9 px · per-source token color                                  |
| Branch             | 10 px monospaced · `textSecondary`                             |
| Context / session name | 11 px · `textSecondary`                                    |
| Status label       | 10 px medium · status-tinted                                   |
| Timestamp          | 10 px · `textMuted` · refreshes every 10 s                     |
| Selected/hover     | `cardSelectionStyle` overlay (no shadow)                       |
| Attention pulse    | 1.5 s ease-in-out, autoreverse on `needsAttention` statuses    |

### Header bar (`HeaderView.swift`)

| Property       | Value                                                              |
|----------------|--------------------------------------------------------------------|
| Padding        | 16 px horizontal · 12 px vertical                                  |
| Status accent  | 3×14 px rounded rect, color = highest-priority status              |
| Title          | 13 px semibold · `textPrimary` ("cctop")                           |
| Trailing       | `StatusChip` row in priority order: permission → attention → working → idle |
| Drag area      | Entire header is a draggable `WindowDragArea` with custom move cursor |

### Status chip (`StatusChip.swift`)

| Property      | Value                                                |
|---------------|------------------------------------------------------|
| Dot           | 5×5 px filled circle, status color                   |
| Count         | 10 px in matching color                              |
| Padding       | 6 px horizontal · 2 px vertical                      |
| Background    | Status color @ 10% opacity                           |
| Radius        | 4 px                                                 |
| Visibility    | Hidden when count is 0                               |

### Notch pill (`NotchStatusView.swift`)

Always black, regardless of theme — it's OS chrome that meets the camera notch.

| Property    | Value                                                                 |
|-------------|-----------------------------------------------------------------------|
| Background  | `Color.black` @ 90% opacity                                           |
| Shape       | `NotchTabShape` — flat top + right, only bottom-left rounded (radius 6) |
| Grid icon   | 11×11, 2×2 cells, tints to accent when `needsAction > 0`              |
| Status bar  | 36×4 capsule with proportional segments                               |
| Padding     | 5 / 2 / 4 / 5 (l / r / t / b)                                         |

### Segmented picker (`AmberSegmentedPicker`)

| Property         | Value                                                |
|------------------|------------------------------------------------------|
| Outer radius     | 5 px                                                 |
| Inner radius     | 3 px                                                 |
| Outer padding    | 2 px                                                 |
| Label            | 10 px medium                                         |
| Inner padding    | 8 px horizontal · 3 px vertical                      |
| Active fill      | `textPrimary` @ 10% opacity                          |
| Hover fill       | `textPrimary` @ 5% opacity                           |
| Active text      | `segmentActiveText` (= `textPrimary`)                |
| Inactive text    | `segmentText` (= `textMuted`)                        |
| Animation        | `easeOut(0.15)`                                      |

### Shortcut badge (`ShortcutBadge`)

| Property      | Value                                                |
|---------------|------------------------------------------------------|
| Font          | 10 px medium monospaced                              |
| Padding       | 6 px horizontal · 2 px vertical                      |
| Background    | `textPrimary` @ 8% (12% on hover)                    |
| Radius        | 3 px                                                 |

### Tab button (Active / Recent)

Selected tab gets the accent underline. Counts render as inline `(n)` in
`textMuted`. 6 px horizontal padding between tabs.

### Hero pill (`site/index.html` — `.hero-pill`)

The marketing site's signature element: the menubar status icon blown up
to hero scale. Pure black background, brand-orange `cctop_` wordmark, and a
168×14 px proportional status bar with four segments using real status colors.

| Property    | Value                                                                 |
|-------------|-----------------------------------------------------------------------|
| Background  | `#000`                                                                |
| Border      | `1px solid white@10%`                                                 |
| Shadow      | `0 18px 36px -22px var(--accent)` (single accent-tinted glow)         |
| Padding     | `5px 8px 5px 12px`                                                    |
| Radius      | `999px` (full pill)                                                   |
| Wordmark    | 12 px semibold mono · `var(--accent)` · letter-spacing `0.02em`       |
| Bar         | 168×14, radius 999, four segments: working / attention / permission / idle |

### Install card (`site/index.html` — `.install-card`)

| Property     | Value                                                                |
|--------------|----------------------------------------------------------------------|
| Background   | `var(--surface)` (`#24283b`)                                         |
| Border       | `1px solid var(--line)`                                              |
| Radius       | `var(--radius)` (10 px)                                              |
| Padding      | 28 px (24 px on mobile)                                              |
| Grid         | `1.05fr 1fr` columns, 36 px gap                                      |
| Brew row     | Mono code on `--bg-2`, 1 px border, 8 px radius, 10/12 padding       |
| Copy button  | 11 px mono, transparent, swaps to checkmark + "copied" on success    |

### FAQ details (`site/index.html` — `.faq details`)

Each question is a native `<details>` element with a custom `+` marker that
rotates 45° to `×` on open via Web Animations API. Body smooth-expands height
+ opacity over 340 ms (open) / 280 ms (close), eased with the global
`cubic-bezier(0.25, 1, 0.5, 1)`.

### Pill button (`.pill`)

| Variant           | Background                | Text color                |
|-------------------|---------------------------|---------------------------|
| Default           | `var(--surface)`          | `var(--fg)`               |
| Hover             | `var(--surface-2)`        | `var(--fg)`               |
| Primary           | `var(--accent)`           | `#1a1b26` (panel bg)      |
| Primary hover     | `filter: brightness(1.05)`| —                         |

Heights: 34 px standard, 42 px `lg`. Radius `999px`. Border
`1px solid var(--line-strong)`.

## 5. Layout Principles

### Spacing scale

A small, consistent set is used everywhere:

```
2 · 4 · 6 · 8 · 9 · 12 · 14 · 16
```

Anything outside this list is suspect. Larger gaps (28 / 32 / 36 / 56 / 80) are
site-only and reserved for sections, not components.

### App panel

| Property                  | Value                                          |
|---------------------------|------------------------------------------------|
| Width                     | Fixed (~320 px)                                |
| Header padding            | 16 / 12 (h / v)                                |
| Tab bar padding           | 12 / 6                                         |
| Card padding              | 8 / 9                                          |
| Footer padding            | 16 / 7                                         |
| Scroll area max height    | 290 px (then scrolls)                          |
| Card spacing              | 0 (dividers between, padded 16 px horizontal)  |
| Settings overlay padding  | 8 px vertical, fills remaining height          |

The panel reflows in **height only**; width is fixed to keep card layout
predictable. When sessions overflow 290 px, the inner area scrolls and the
header / footer / tab bar stay anchored.

### Site grid

| Property              | Value                                                 |
|-----------------------|-------------------------------------------------------|
| Wrap                  | `max-width: 1200px`, centered                         |
| Gutter                | 32 px (20 px under 720 px viewport)                   |
| Section padding       | `80px 0` (`56px 0` under 720 px)                      |
| Hero padding          | `20px 0 32px` (tight to keep CTAs above the fold)     |
| Top header height     | 60 px sticky, with `backdrop-filter: blur(14px) saturate(140%)` |
| Scroll padding top    | 72 px (so anchor links clear the sticky header)       |
| Hero content grid     | `minmax(0, 1.05fr) minmax(0, 1fr)` with 56 px gap     |
| Themes / tools grid   | `repeat(4, 1fr)` desktop · `repeat(2, 1fr)` ≤ 900 px  |
| Feature row           | `1fr 1fr` desktop · single column ≤ 980 px            |
| Install card grid     | `1.05fr 1fr` desktop · single column ≤ 900 px         |

### Density philosophy

> **Function earns its pixels.** Every element must justify its space. No
> decorative chrome, no padding for padding's sake. Dense but not cramped —
> utilitarian density with breathing room.

Concretely:

- Cards in the panel use 9 px vertical padding so a 320 px panel can fit
  four sessions before scrolling.
- Inter-card separation is a 1 px divider with 16 px horizontal padding, not
  a margin — preserves the rhythm without inflating the panel.
- Status chips disappear at count 0; the layout never holds space for absent
  meaning.
- The site uses `text-wrap: balance` / `pretty` and `max-width` on copy so
  no line ever stretches past comfortable reading width (50–70 ch).

### Alignment

- Panel: leading-aligned text by default; status / time stack right-aligned
  in the trailing column.
- Site: hero is left-aligned; section headings are left-aligned with copy
  beneath; CTAs flow inline.
- Centered text is reserved for empty states, captions, and theme-card names.

### Vertical rhythm

App is single-column with consistent 9 px card height beats. The site uses
80 px section padding as the macro rhythm, with `feat-block + feat-block`
spaced 80 px and individual feature rows aligned to a 56 px column gap.

## 6. Depth & Elevation

cctop has **no decorative shadows**. Hierarchy comes from radius, hairline
borders, and surface tinting — not drop shadows. The only shadow in the
entire system is a single accent-tinted glow under the hero pill on the
website.

### Radius scale

| Radius | Usage                                                              |
|--------|--------------------------------------------------------------------|
| 1.5 px | Session-card accent stripe                                         |
| 2 px   | Navigate-mode badge (16×16 status square)                          |
| 3 px   | Inner segment of segmented picker, shortcut badge                  |
| 4 px   | Status chip, gear button hover background                          |
| 5 px   | Outer segmented picker container                                   |
| 6 px   | Notch tab (bottom-left only), brew code block, focus-visible outline |
| 8 px   | Theme card image, install card brew row                            |
| 10 px  | Panels, theme cards, tool cards, install card (`--radius`)         |
| 14 px  | Hero screenshot frame                                              |
| 999 px | Pills, hero pill, status bar capsule                               |

### Surface elevation

Treat the app and the site the same way: stack tinted surfaces by alpha,
not shadow.

#### App (within `panelBackground`)

| Layer            | Treatment                                                          |
|------------------|--------------------------------------------------------------------|
| Panel base       | `panelBackground` (per-theme)                                      |
| Card resting     | Transparent — only the accent stripe and text                      |
| Card hover       | `cardSelectionStyle` (subtle tint via `cardBackground`)            |
| Card selected    | Same overlay as hover                                              |
| Status chip      | Status color @ 10% over panel                                      |
| Settings overlay | `panelBackground` (opaque), entered with `move(edge: .top)`        |
| Settings exit    | Custom `RollUpEffect` instead of move-out                          |
| Divider          | `cardBorder` 1 px (white@4% / black@4%)                            |

#### Site

| Layer       | Treatment                                                     |
|-------------|---------------------------------------------------------------|
| Page base   | `--bg`                                                        |
| Sunk row    | `--bg-2` (badges, brew code)                                  |
| Card        | `--surface` with 1 px `--line` border                         |
| Card hover  | `--surface-2` with `--line-strong` border                     |
| Sticky nav  | `color-mix(in oklab, var(--bg) 75%, transparent)` + 14 px backdrop blur |
| Hero pill   | `#000` with single `0 18px 36px -22px var(--accent)` glow     |

### Borders

The hairline border is the load-bearing element. `--line` (10% alpha) for
resting state, `--line-strong` (18% alpha) for hover or active. Never use
solid `1px solid #000` or thick borders.

### Focus rings

| Surface | Treatment                                                      |
|---------|----------------------------------------------------------------|
| App     | System-default focus ring (we don't override)                  |
| Site    | `outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 4px` on `:focus-visible` |

### Selection highlight (site)

`::selection` uses `color-mix(in oklab, var(--accent) 35%, transparent)` so
text selection visually matches the accent without screaming.

### Animation curve

A single global ease — `cubic-bezier(0.25, 1, 0.5, 1)` (`--ease-out`) — is
shared across hover transitions, scroll-spy underlines, FAQ details, scroll
reveal, and the smooth in-page scroll. One curve = consistent feel.

## 7. Do's and Don'ts

The six principles that drive every visual decision, paired with concrete
anti-patterns.

### 1. Glanceable over interactive

**Do** — Status must be understood in under a second. Color **and** text
together. Proportional bars instead of numeric counts where possible.
Spatial consistency across renders (same session in the same place).

**Don't** — Tooltips for primary information. Numbers without context
("3" — three what?). Color alone (color-blind users, peripheral vision).

### 2. Native over novel

**Do** — Use San Francisco. Use NSPanel. Use NSStatusItem. Use macOS
keyboard conventions (⌘W to close, Escape to dismiss). Match the look of
high-quality first-party apps.

**Don't** — Custom font for the app UI. Web-style buttons, web-style modals,
web-style tooltips. CSS-in-JS-feeling chrome. Anything that screams "this
was a webview."

### 3. Craft in the details

**Do** — Notice the small things: the proportional notch bar, the ⌘ shortcut
badges, the smooth FAQ accordion, the accent-tinted hero glow. Sweat
contrast ratios (the site bumps `--fg-mute` past WCAG AA on small text).
Round-trip every change in the SwiftUI Preview before shipping.

**Don't** — Ship pixel-perfect mockups that don't survive real data.
Skip the empty state. Skip the keyboard path. "Good enough" the contrast.

### 4. Function earns its pixels

**Do** — Hide elements with no value to show (chips at count 0, source
badge when only one source is present, recent tab when there's no recent).
Use the smallest type that's still legible at 1× on a Retina display.

**Don't** — Decorative shadows, gradient overlays, gratuitous icons,
section headers without sections, padding for padding's sake.

### 5. Keyboard-first, mouse-friendly

**Do** — Every action reachable from the keyboard: ↑/↓ to navigate, Return
to jump, Tab/←/→ to switch tabs, 1–9 in navigate mode, Escape to reset.
Hover states polished but never required.

**Don't** — Keyboard as a power-user-only afterthought. Modal dialogs that
trap focus poorly. Click targets smaller than 28×28 px on mouse-only paths.

### 6. Prototype in HTML first

**Do** — Build new UI first as a self-contained HTML file in `/tmp/`,
review in browser, then port to Swift with **exact** matching values
(hex, padding, radius). Keeps design intent and implementation aligned.

**Don't** — Eyeball values in Xcode and "tune later." Drift between mockup
hex and implementation hex. Skip the prototype because "it's just one
view."

### Other guardrails

| Don't                                                  | Do                                                  |
|--------------------------------------------------------|-----------------------------------------------------|
| Add emoji to UI text                                   | Use status color + label pairs                      |
| Use warm- or cool-tinted grays                         | Use neutral grays (`textPrimary`, `textMuted`, …)   |
| Introduce a fifth status color                         | Map new statuses through the existing 5 roles       |
| Hand-edit version strings                              | Use `scripts/bump-version.sh`                       |
| Add a new theme without all 14 token roles             | Match the four-theme matrix in `AppTheme.swift`     |
| Use raw `Color.blue`/`.green`/etc. in views            | Use semantic tokens (`textPrimary`, `statusGreen`)  |
| Drop a custom font into the app bundle                 | Stay on `.system` for the app                       |
| Override the `--ease-out` curve                        | Reuse it everywhere for consistent motion           |
| Drop a third-party UI kit into the site                | Hand-rolled CSS, no build step, single HTML file    |

## 8. Responsive Behavior

### App

The menubar app isn't responsive in the web sense — the panel is fixed
width — but it adapts to **display configuration**:

| Configuration                         | Behavior                                                                 |
|---------------------------------------|--------------------------------------------------------------------------|
| Built-in display with camera notch    | Notch pill shows next to the notch; main panel anchors to whichever (pill or menubar icon) is visible |
| Non-notch built-in / external display | No notch pill; menubar icon (44 px) is always visible                    |
| Clamshell / display change            | `NSApplication.didChangeScreenParametersNotification` re-evaluates       |
| Dragged off-screen                    | Panel position clamps to screen bounds on next show                      |
| Theme switch (system or user)         | All `Color` tokens re-resolve via `NSColor(name:)` dynamic provider      |
| User drags the panel                  | New position persists across launches; double-click header restores default |

Detection uses `NSScreen.builtin?.hasPhysicalNotch` (via
`safeAreaInsets.top > 0`). The panel adapts its anchor accordingly — see
`menubar/CctopMenubar/Services/NotchStatusController.swift`.

### Notch pill

The pill is **always 36×4 px wide** but its segments scale proportionally
with status counts via `StatusCounts.barSegments(forWidth:)`. Single-status
sessions render one segment. Mixed sessions get a minimum visible slice for
each non-zero category so a single attention-needing session in twenty
working ones is still visible.

### Site breakpoints

| Breakpoint   | Trigger                                                              |
|--------------|----------------------------------------------------------------------|
| ≤ 1040 px    | Top nav collapses; only brand + GitHub + Download remain             |
| ≤ 980 px     | Hero stacks (text over screenshot); feature rows stack; install card stacks |
| ≤ 900 px     | Themes / tools grid drops from 4 cols to 2; tier rows stack          |
| ≤ 720 px     | Wrap gutter shrinks 32 → 20 px; section padding shrinks 80 → 56 px; hero padding tightens |
| ≤ 520 px     | GitHub pill loses its label (icon-only) so Download CTA fits         |

The site uses `text-wrap: balance` on headings and `text-wrap: pretty` on
body so line breaks remain elegant at every width without manual `<br>`.

### Touch targets

The site is desktop-first (cctop is macOS-only) but stays touch-usable:

- All pills are ≥ 34 px tall (42 px for `lg`).
- FAQ summaries use a 18 px row with the entire row clickable.
- Theme cards have 12 px internal padding plus the image as a click target.
- No hover-only affordances — every hover state has a focus equivalent.

### Reduced motion

Both surfaces respect `prefers-reduced-motion: reduce`:

| Surface | Behavior under reduced motion                                                  |
|---------|---------------------------------------------------------------------------------|
| App     | Pulse animation on attention statuses still runs (it's a status indicator, not decoration), but the segmented picker / overlay transitions snap rather than ease |
| Site    | All transitions and animations forced to `0.01ms`; smooth-scroll swaps to instant `window.scrollTo`; FAQ height tween is bypassed (native `<details>` toggle); reveal-on-scroll fade is disabled (everything pre-revealed) |

### Color scheme

App: tracks system Light/Dark via `NSAppearance` — every token in
`Color+Theme.swift` is a dynamic `NSColor(name:)` that re-resolves on
appearance change. Theme choice (Claude / Tokyo Night / Gruvbox / Nord) is
orthogonal and user-controlled.

Site: dark-only. Tokyo Night palette is hard-coded; there is no
`prefers-color-scheme: light` branch (and no plan to add one — the site
is the dark menubar's natural surface).

### High DPI

App ships at 2× via `Assets.xcassets`. Site assets use intrinsic `width` /
`height` attributes so the browser reserves layout space; raster
screenshots are sourced from `docs/*.png` and propagated to the site via
the GitHub raw URL — no per-DPI variants needed because the screenshots
are already 2×.

## 9. Agent Prompt Guide

A cheat-sheet for prompting AI tools (or new contributors) to produce
cctop-consistent UI.

### One-line palette identifiers

| Theme        | Dark accent | Dark bg   | Dark fg   | Light accent | Light bg  | Light fg  |
|--------------|-------------|-----------|-----------|--------------|-----------|-----------|
| Claude       | `#D97757`   | `#262624` | `#E8E6DC` | `#D97757`    | `#E8E6DC` | `#141413` |
| Tokyo Night  | `#F7768E`   | `#1A1B26` | `#C0CAF5` | `#2959AA`    | `#E6E7ED` | `#343B59` |
| Gruvbox      | `#FE8019`   | `#282828` | `#EBDBB2` | `#AF3A03`    | `#FBF1C7` | `#3C3836` |
| Nord         | `#BF616A`   | `#2E3440` | `#ECEFF4` | `#BF616A`    | `#ECEFF4` | `#2E3440` |

### Status colors (Tokyo Night dark — the canonical reference)

```
Permission  #F7768E   (red/pink)
Attention   #FF9E64   (orange)
Working     #9ECE6A   (green)
Compacting  #BB9AF7   (purple, shared with subagent badge)
Idle        #565D78   (muted blue-gray)
```

### Default font stacks

```
App sans:    -apple-system, BlinkMacSystemFont, system-ui (SF)
App mono:    .system(design: .monospaced) (SF Mono)
Site sans:   'IBM Plex Sans', -apple-system, BlinkMacSystemFont, system-ui
Site mono:   'IBM Plex Mono', ui-monospace, SFMono-Regular, Menlo
Site serif:  'Instrument Serif', ui-serif, Georgia
```

### Type ladder (app)

```
9   source badge
10  branch (mono), timestamp, status label, segment label
11  settings label, context line, shortcut badge (mono)
12  empty state, banner body
13  project name (medium), header title (semibold)
```

### Spacing ladder

```
2 · 4 · 6 · 8 · 9 · 12 · 14 · 16    (app + components)
20 · 28 · 32 · 36 · 56 · 80         (site sections only)
```

### Radius ladder

```
1.5  card accent stripe
2    navigate badge
3    inner segment, shortcut badge
4    chip, hover background
5    outer segment
6    notch tab, brew code, focus ring
8    theme card image
10   panel, theme card, tool card, install card
14   hero screenshot frame
999  pills, status bar capsule
```

### Ready-to-use prompt fragments

> "Use cctop's Tokyo Night dark palette: panel `#1A1B26`, primary text
> `#C0CAF5`, secondary `#787C99`, accent `#F7768E`. Status colors:
> permission `#F7768E`, attention `#FF9E64`, working `#9ECE6A`,
> idle `#565D78`. No drop shadows; hierarchy via 1 px hairline borders
> at 10–18% alpha and 4 / 6 / 10 px corner radii."

> "Type stack: SF system for the app, IBM Plex Sans / IBM Plex Mono /
> Instrument Serif for the site. Body 11–13 px in the app, hero `clamp`
> 44–112 px on the site. Status meaning is **always** carried by both
> color and text — never color alone."

> "Layout: panel is fixed-width (~320 px), card padding 8/9, header padding
> 16/12. Use the spacing scale 2/4/6/8/9/12/14/16. Hide elements at zero
> count instead of reserving space. Every interaction is keyboard-reachable."

> "Don't add decorative shadows, gradient overlays, custom fonts in the app,
> or warm/cool-tinted grays. Match the existing 9 / 10 / 11 / 12 / 13 px
> type ladder; do not introduce new sizes. Status colors come from the
> five existing roles — never invent a sixth."

### Where to look in the codebase

| Asking about… | Read this first                                                  |
|---------------|------------------------------------------------------------------|
| Color tokens  | `menubar/CctopMenubar/Models/Color+Theme.swift`                  |
| Theme hex values | `menubar/CctopMenubar/Models/AppTheme.swift`                  |
| Status meaning | `menubar/CctopMenubar/Views/SessionStatus+UI.swift`             |
| Card layout   | `menubar/CctopMenubar/Views/SessionCardView.swift`               |
| Header layout | `menubar/CctopMenubar/Views/HeaderView.swift`                    |
| Notch pill    | `menubar/CctopMenubar/Views/NotchStatusView.swift`               |
| Web tokens    | `site/index.html` `:root` block (top of `<style>`)               |
