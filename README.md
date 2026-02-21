# cctop

[![GitHub release](https://img.shields.io/github/v/release/st0012/cctop?v=1)](https://github.com/st0012/cctop/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**A keyboard-first menubar app to monitor and jump between Claude Code and opencode sessions — minimum setup required.**

Works with your existing editor and terminal. No IDE needed, no workflow changes — just install the app, connect your tools, and every session shows up in a floating panel you can navigate with your keyboard.

<p align="center">
  <img src="docs/menubar-light.png" alt="cctop menubar popup (light mode)" width="340">
  &nbsp;&nbsp;
  <img src="docs/menubar-dark.png" alt="cctop menubar popup (dark mode)" width="340">
</p>

<p align="center"><em>Monitoring Claude Code and opencode sessions side by side — light and dark mode.</em></p>

## Features

**At-a-glance status.** A floating menubar panel shows all active sessions with color-coded badges: idle, working, waiting for input, waiting for permission, compacting. See the current prompt or tool in use (e.g. "Editing auth.ts") without switching windows.

**Jump directly to any session.** Click a session card to raise its VS Code, Cursor, or iTerm2 window — or stay on the keyboard. Arrow keys to browse, Enter to jump, Tab to switch tabs.

**Refocus mode.** Hit a global hotkey to overlay numbered badges (1–9) on every session card, then press the number to jump instantly.

<p align="center">
  <img src="docs/menubar-refocus.png" alt="cctop refocus mode with numbered badges" width="340">
</p>

**Recent Projects.** A second tab keeps session history so you can reopen past projects easily.

<p align="center">
  <img src="docs/menubar-recent.png" alt="cctop recent projects tab" width="340">
</p>

**Compact mode.** Press Cmd+M to collapse the panel to a slim header bar showing just the status counts. Press Cmd+M again to switch back. Click the header or use the refocus shortcut to temporarily expand, or press Escape to return focus to your previous app.

<p align="center">
  <img src="docs/menubar-compact-light.png" alt="cctop compact mode showing header-only view" width="340">
</p>

Works with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [opencode](https://opencode.ai).

## Installation

### Step 1: Install the app

**Homebrew:**

```bash
brew tap st0012/cctop
brew install --cask cctop
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
No. The plugin writes a small JSON file on each event and returns immediately. There is no measurable impact on performance.

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

**My panel shrank to just the header bar — how do I get it back?**
You activated compact mode (Cmd+M). Press Cmd+M again to return to the normal view. You can also click the header to temporarily expand and see your sessions. An amber underline under "cctop" indicates compact mode is active.

**No sessions are showing up — what do I check?**
First, make sure you restarted sessions after installing the plugin. Then check if session files exist: `ls ~/.cctop/sessions/`. If the directory is empty, the plugin isn't writing data — verify it's installed correctly (see Step 2). If files exist but the menubar shows nothing, try restarting the cctop app.

**What happens if opencode (or Claude Code) crashes?**
cctop detects dead sessions automatically. It checks whether each session's process is still running and removes stale entries. No manual cleanup needed.

**Does the opencode plugin need Node.js or Bun installed separately?**
No. The plugin runs inside opencode's built-in Bun runtime. You don't need to install anything beyond the plugin file itself.

**Why does the app need to be in /Applications/?**
The Claude Code plugin looks for `cctop-hook` inside `/Applications/cctop.app`. Installing elsewhere breaks the hook path. (The opencode plugin writes session files directly and does not need the app in a specific location.)

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

Both tools write to the same session store — the menubar app doesn't care where the data comes from.

```
┌─────────────┐    hook fires     ┌────────────┐
│ Claude Code │ ────────────────> │ cctop-hook │ ──┐
│  (session)  │  SessionStart,    │  (Swift)   │   │  writes JSON
│             │  Stop, PreTool,   │            │   │  per-session
└─────────────┘  Notification,…   └────────────┘   │
                                                   ▼
                                           ┌───────────────────┐
                                           │ ~/.cctop/sessions │
                                           │   ├── 123.json    │
                                           │   ├── 456.json    │
                                           │   └── 789.json    │
                                           └──────────┬────────┘
┌─────────────┐   plugin event    ┌────────────┐  ▲   │
│  opencode   │ ────────────────> │ JS plugin  │ ─┘   │ file watcher
│  (session)  │  session.status,  │            │      ▼
│             │  tool.execute,…   │            │  ┌──────────────┐
└─────────────┘                   └────────────┘  │ Menubar app  │
                                                  │ (live status)│
                                                  └──────────────┘
```

1. Each tool has its own plugin that translates events into session state
2. **Claude Code**: hooks invoke `cctop-hook` (a Swift CLI), which writes JSON session files
3. **opencode**: a JS plugin listens to events and writes the same JSON format directly
4. Both write to `~/.cctop/sessions/` — the menubar app watches this directory and displays live status

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
