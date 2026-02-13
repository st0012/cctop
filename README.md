# cctop

[![CI](https://github.com/st0012/cctop/actions/workflows/ci.yml/badge.svg)](https://github.com/st0012/cctop/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/st0012/cctop)](https://github.com/st0012/cctop/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Know which Claude Code sessions need you — without switching tabs.**

If you run multiple Claude Code sessions across different projects, you know the pain: constantly cycling through terminal tabs to check which ones are waiting for input, which need permission, and which are still working. cctop sits in your macOS menubar and shows you the status of every session at a glance — so you only switch when something actually needs you.

<p align="center">
  <img src="docs/menubar-light.png" alt="cctop menubar popup (light mode)" width="340">
  &nbsp;
  <img src="docs/menubar-dark.png" alt="cctop menubar popup (dark mode)" width="340">
</p>

## Features

- Lives in your menubar — always one click away
- Real-time session status: idle, working, waiting for input, waiting for permission
- Shows current tool or prompt context for each session
- Click to jump to the session's VS Code or Cursor window
- Native macOS menubar app — lightweight and always running

## Installation

### Homebrew

```bash
brew tap st0012/cctop
brew install --cask cctop
```

### Download manually

1. Download `cctop-macOS-arm64.zip` (Apple Silicon) or `cctop-macOS-x86_64.zip` (Intel) from the [latest release](https://github.com/st0012/cctop/releases/latest)
2. Unzip and move `cctop.app` to `/Applications/`
3. Open the app: `open /Applications/cctop.app`

Or from the command line:

```bash
curl -sL https://github.com/st0012/cctop/releases/latest/download/cctop-macOS-arm64.zip -o cctop.zip
unzip cctop.zip
mv cctop.app /Applications/
open /Applications/cctop.app
```

### Install the Claude Code plugin

The plugin registers hooks so Claude Code reports session activity to cctop.

```bash
claude plugin marketplace add st0012/cctop
claude plugin install cctop
```

Restart any running Claude Code sessions to activate hooks (type `/exit` then reopen).

### Build from source

Requires Xcode 16+.

```bash
./scripts/bundle-macos.sh
cp -R dist/cctop.app /Applications/
open /Applications/cctop.app
```

## How It Works

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

## Privacy

All data stays local. cctop stores session metadata (status, project name, timestamps) in `~/.cctop/sessions/`. Nothing is sent to any server.

## FAQ

**Does cctop slow down Claude Code?**
No. The hook runs as a separate process that writes a small JSON file and exits immediately. There is no measurable impact on Claude Code performance.

**Does it work with Cursor / VS Code / other editors?**
Yes. cctop monitors Claude Code sessions regardless of which editor you use. Clicking a session card focuses the correct VS Code or Cursor project window. For other editors, it activates the app but may not target the specific window.

## License

MIT
