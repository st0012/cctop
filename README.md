# cctop

[![GitHub release](https://img.shields.io/github/v/release/st0012/cctop)](https://github.com/st0012/cctop/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Know which Claude Code sessions need you — without switching tabs.**

A macOS menubar app that shows the status of every Claude Code session at a glance — so you only switch when something actually needs you.

<p align="center">
  <img src="docs/menubar-screenshot.png" alt="cctop menubar popup" width="380">
</p>

<p align="center"><em>Monitoring 4 Claude Code sessions across projects.</em></p>

<p align="center">
  <img src="docs/menubar-dark.png" alt="cctop status badges" width="340">
</p>

<p align="center"><em>Status badges show what's urgent — permission requests, waiting input, or still working.</em></p>

## Features

- Lives in your menubar — one click or a keyboard shortcut away
- Color-coded status badges: idle, working, waiting for input, waiting for permission, compacting
- See what each session is doing: the current prompt, tool being used, or last activity
- Click a session to jump to its VS Code or Cursor window
- Native macOS app — lightweight, always running, no Electron

## Installation

### Step 1: Install the app

**Homebrew:**

```bash
brew tap st0012/cctop
brew install --cask cctop
```

Or [download the latest release](https://github.com/st0012/cctop/releases/latest) — the app is signed and notarized by Apple.

### Step 2: Install the Claude Code plugin (required)

The app needs this plugin to receive session events from Claude Code.

```bash
claude plugin marketplace add st0012/cctop
claude plugin install cctop
```

Restart any running Claude Code sessions to activate (`/exit` then reopen). New sessions are tracked automatically — no per-project config needed.

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

**Does cctop slow down Claude Code?**
No. The hook runs as a separate process that writes a small JSON file and exits immediately. There is no measurable impact on Claude Code performance.

**Do I need to configure anything per project?**
No. Once the plugin is installed, all Claude Code sessions are automatically tracked. No per-project setup required.

**Does it work with VS Code and Cursor?**
Yes. Clicking a session card focuses the correct project window.

**Does it work with Warp, iTerm2, or other terminals?**
It activates the app but cannot target a specific terminal tab. You'll need to find the right tab manually.

**How does cctop name sessions?**
By default, the project directory name (e.g. `/path/to/my-app` shows as "my-app"). If you rename a session with `/rename` in Claude Code, cctop picks that up too.

**Why does the app need to be in /Applications/?**
The plugin looks for `cctop-hook` inside `/Applications/cctop.app`. Installing elsewhere breaks the hook path.

## Uninstall

```bash
# Remove the menubar app
rm -rf /Applications/cctop.app

# Remove the Claude Code plugin
claude plugin remove cctop
claude plugin marketplace remove cctop

# Remove session data and config
rm -rf ~/.cctop
```

If installed via Homebrew: `brew uninstall --cask cctop`

<details>
<summary>How it works</summary>

```
┌─────────────┐    hook fires     ┌────────────┐    writes JSON    ┌───────────────────┐
│ Claude Code │ ────────────────> │ cctop-hook │ ────────────────> │ ~/.cctop/sessions │
│  (session)  │  SessionStart,    │   (CLI)    │   per-session     │   ├── abc.json    │
│             │  Stop, PreTool,   │            │   state file      │   ├── def.json    │
│             │  Notification,…   │            │                   │   └── ghi.json    │
└─────────────┘                   └────────────┘                   └──────────┬────────┘
                                                                              │ file watcher
                                                                              ▼
                                                                      ┌──────────────┐
                                                                      │ Menubar app  │
                                                                      │ (live status)│
                                                                      └──────────────┘
```

1. The cctop plugin registers hooks with Claude Code
2. When session events fire (start, prompt, tool use, stop, notifications), Claude Code invokes `cctop-hook`
3. `cctop-hook` writes/updates a JSON state file per session in `~/.cctop/sessions/`
4. The menubar app watches this directory and displays live status for all sessions

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
