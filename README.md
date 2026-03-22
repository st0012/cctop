# cctop

[![GitHub release](https://img.shields.io/github/v/release/st0012/cctop?v=1)](https://github.com/st0012/cctop/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**A keyboard-first menubar app to monitor and jump between Claude Code and opencode sessions — minimum setup required.**

Works with your existing editor and terminal. No IDE needed, no workflow changes — just install the app, connect your tools, and every session shows up in a floating panel you can navigate with your keyboard.

<table align="center">
  <tr>
    <td align="center"><img src="docs/menubar-tokyonight-dark.png" alt="cctop menubar popup (Tokyo Night dark)" width="340"></td>
    <td align="center"><img src="docs/menubar-light.png" alt="cctop menubar popup (Claude light)" width="340"></td>
  </tr>
  <tr>
    <td align="center"><em>Tokyo Night (dark)</em></td>
    <td align="center"><em>Claude (light)</em></td>
  </tr>
</table>

## Features

**At-a-glance status.** A floating menubar panel shows all active sessions with color-coded badges: idle, working, waiting for input, waiting for permission, compacting. See the current prompt or tool in use (e.g. "Editing auth.ts") without switching windows.

**Jump directly to any session.** Click a session card to raise its VS Code, Cursor, or iTerm2 window — or stay on the keyboard. Arrow keys to browse, Enter to jump, Tab to switch tabs.

**Draggable panel.** Drag the header to reposition the panel anywhere on screen — position persists across launches. Double-click the header to snap back to the default menubar anchor.

<p align="center">
  <img src="docs/draggable-panel-demo.gif" alt="Dragging the cctop panel to a new position" width="680">
</p>

**Navigate mode.** Hit a global hotkey to overlay numbered badges (1–9) on every session card, then press the number to jump instantly.

<p align="center">
  <img src="docs/menubar-navigate.png" alt="cctop navigate mode with numbered badges" width="340">
  <br><em>Navigate mode — press 1–9 to jump</em>
</p>

**Recent Projects.** A second tab keeps session history so you can reopen past projects easily.

<p align="center">
  <img src="docs/menubar-recent.png" alt="cctop recent projects tab" width="340">
  <br><em>Recent projects tab</em>
</p>

**Smart status icon.** See session health without opening the panel:
- **Status bar:** A proportional bar next to the icon shows green (working), amber (needs input), red (permission pending), or gray (idle).
- **Attention tint:** When any session needs your input, the icon shifts to terracotta — visible even in your peripheral vision.
- **Notch-aware:** On MacBooks where the notch hides the menubar icon, a small status pill appears next to the camera so you always have a signal.

<p align="center">
  <img src="docs/status-icon.png" alt="Status icon states: all healthy, needs attention, and notch pill" width="680">
</p>

Works with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [opencode](https://opencode.ai).

### Themes

Four color schemes inspired by beloved developer tools — each with dark and light variants.

| Claude | Tokyo Night | Gruvbox | Nord |
|:------:|:-----------:|:-------:|:----:|
| <img src="docs/theme-claude-dark.png" width="180"> | <img src="docs/theme-tokyoNight-dark.png" width="180"> | <img src="docs/theme-gruvbox-dark.png" width="180"> | <img src="docs/theme-nord-dark.png" width="180"> |

Switch themes in Settings > Appearance > Color.

## Installation

### Step 1: Install the app

**Homebrew:**

```bash
brew install --cask st0012/cctop/cctop
```

Or [download the latest release](https://github.com/st0012/cctop/releases/latest) — the app is signed and notarized by Apple.

### Step 2: Connect your tools

Follow the app's instructions to install Claude Code and/or opencode plugin.

## Privacy

**No network access. No analytics. No telemetry. All data stays on your machine.**

cctop stores only:

- Session status (idle / working / waiting)
- Project directory name
- Last activity timestamp
- Current tool or prompt context

This data lives in `~/.cctop/sessions/` as plain JSON files. You can inspect it anytime:

```bash
ls ~/.cctop/sessions/
cat ~/.cctop/sessions/*.json | python3 -m json.tool
```

## FAQ

**Does cctop slow down my coding tool?**
No. The plugin calls a lightweight native binary (`cctop-hook`) on each event, which writes a small JSON file and returns immediately. There is no measurable impact on performance.

**Do I need to configure anything per project?**
No. Once the plugin is installed, all sessions are automatically tracked. No per-project setup required.

**Does it work with VS Code and Cursor?**
Yes. Clicking a session card focuses the correct project window.

**Does it work with iTerm2?**
Yes. Clicking a session card raises the correct iTerm2 window, selects the tab, and focuses the pane — even with split panes or multiple windows.

> [!NOTE]
> Requires macOS Automation permission. You'll be prompted to grant it on first use.

**Does it work with Warp or other terminals?**
It activates the app but cannot target a specific terminal tab. You'll need to find the right tab manually.

**How does cctop name sessions?**
By default, the project directory name (e.g. `/path/to/my-app` shows as "my-app"). In Claude Code, you can rename a session with `/rename` and cctop picks that up.

**No sessions are showing up — what do I check?**
First, make sure you restarted sessions after installing the plugin. Then check if session files exist: `ls ~/.cctop/sessions/`. If the directory is empty, the plugin isn't writing data — verify it's installed correctly (see Step 2). If files exist but the menubar shows nothing, try restarting the cctop app.

**What happens if opencode (or Claude Code) crashes?**
cctop detects dead sessions automatically. It checks whether each session's process is still running and removes stale entries. No manual cleanup needed.

**Does the opencode plugin need Node.js or Bun installed separately?**
No. The plugin runs inside opencode's built-in Bun runtime. It calls the `cctop-hook` binary bundled inside the cctop app — no additional dependencies needed.

**Why does the app need to be in /Applications/?**
Both plugins look for `cctop-hook` inside `/Applications/cctop.app`. Installing elsewhere breaks the hook path. (The opencode plugin also checks `~/.cctop/bin/` as a fallback.)

## Uninstall

```bash
# Remove the menubar app
rm -rf /Applications/cctop.app

# Remove the Claude Code plugin
claude plugin remove cctop
claude plugin marketplace remove cctop

# Remove the opencode plugin
rm ~/.config/opencode/plugins/cctop.js

# Remove session data and config
rm -rf ~/.cctop
```

If installed via Homebrew: `brew uninstall --cask cctop`

<details>
<summary>How it works</summary>

Both tools go through `cctop-hook` — a single native binary that manages all session state.

```
┌─────────────┐    hook fires     ┌────────────┐
│ Claude Code │ ────────────────> │ cctop-hook │ ──┐
│  (session)  │  SessionStart,    │  (Swift)   │   │  writes JSON
│             │  Stop, PreTool,   │            │   │  per-session
└─────────────┘  Notification,…   └────────────┘   │
                                       ▲           ▼
┌─────────────┐   plugin event    ┌────┴───────┐  ┌───────────────────┐
│  opencode   │ ────────────────> │ JS plugin  │  │ ~/.cctop/sessions │
│  (session)  │  session.status,  │ (calls     │  │   ├── 123.json    │
│             │  tool.execute,…   │  cctop-hook│  │   └── 456.json    │
└─────────────┘                   └────────────┘  └──────────┬────────┘
                                                             │ file watcher
                                                             ▼
                                                  ┌──────────────┐
                                                  │ Menubar app  │
                                                  │ (live status)│
                                                  └──────────────┘
```

1. Each tool has its own plugin that translates events into `cctop-hook` calls
2. **Claude Code**: shell hooks invoke `cctop-hook` directly
3. **opencode**: a JS plugin translates events and calls `cctop-hook` via `execFileSync`
4. `cctop-hook` writes to `~/.cctop/sessions/` — the menubar app watches this directory and displays live status

</details>

<details>
<summary>Build from source</summary>

Requires Xcode 16+ and macOS 13+.

```bash
git clone https://github.com/st0012/cctop.git
cd cctop
./scripts/bundle-macos.sh
cp -R dist/cctop.app /Applications/
open /Applications/cctop.app
```

</details>

## License

MIT
