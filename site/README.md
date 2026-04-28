# cctop website

Source for the public site at https://cctop.app/.

`index.html` is a single static file. No build step. The deploy is driven by
`.github/workflows/pages.yml`, which uploads this folder as the Pages artifact
on every push to `master` that touches `site/**`. The `CNAME` file in this
folder pins the custom domain (`cctop.app`) on every deploy — without it, the
custom-domain setting gets cleared each time the artifact replaces the site.

## Local preview

```bash
python3 -m http.server 8000 --directory site
# open http://localhost:8000
```

Screenshots are pulled from `https://raw.githubusercontent.com/st0012/cctop/master/docs/`,
so updates to `docs/*.png` and `docs/*.gif` show up on the site automatically once
they land on master — no site change required.

## What auto-syncs vs what you have to update by hand

| Source of truth | Site element | Sync |
|-----------------|--------------|------|
| Latest GitHub Release | Hero badge version (`v0.14.0`) | Auto: a `fetch()` overrides the static value at page load. Static fallback is kept current by `scripts/bump-version.sh`. |
| `docs/*.png`, `docs/*.gif` | Hero shot, feature screenshots, theme cards, install card | Auto via raw GitHub URLs — no site edit needed. |
| `releases/latest/download/cctop-macOS-{arm64,x86_64}.dmg` | All Download buttons | Auto via the `releases/latest/` redirect — no site edit needed. |
| README "Supported tools" table | `#tools` Coding agents grid | Manual — keep names + URLs in sync with the README table. |
| README "Supported Editors & Terminals" table | `#tools` Editors & terminals tiers | Manual — keep the three tiers (exact pane / opens project / activates app) in sync with the README. |
| `Color+Theme.swift`, README themes table | `#themes` cards | Manual — name, accent swatch hex, and `docs/theme-*.png` filename. |
| README FAQ | `#faq` `<details>` entries | Manual. |
| Hero copy, install copy, privacy copy | Hero / install / tools sections | Manual — site has its own short-form copy that mirrors the README's tone. |
| Custom domain (`cctop.app`) | `site/CNAME` | Auto — file ships with every deploy so the Pages "Custom domain" setting persists. |
| Social preview card | `site/og.html` (rendered to PNG externally for OG metadata) | Manual — update copy and re-render to PNG when hero copy or palette changes substantively. |

## When you change the implementation

Before pushing changes that affect anything in the "Manual" rows above, update
`site/index.html` in the same commit. CI deploys whatever lands on master, so
the README and the site should always match what shipped.

For visuals: replace the screenshot under `docs/` and the site will reflect the
new image without any site edit.
