# cctop

[![CI](https://github.com/st0012/cctop/actions/workflows/ci.yml/badge.svg)](https://github.com/st0012/cctop/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A macOS menubar app for monitoring Claude Code sessions across workspaces.

See all your Claude Code sessions at a glance — which are working, which need your attention, and which are idle. Click any session to jump straight to it.

<p align="center">
  <img src="docs/menubar.png" alt="cctop menubar popup" width="320">
</p>

## Why cctop?

When you run multiple Claude Code sessions across different projects, it's hard to know which ones need your attention. You end up cycling through terminal tabs checking on each one. cctop sits in your menubar and shows you the status of every session at a glance — so you only switch when something actually needs you.

## Features

- Lives in your menubar — always one click away
- Real-time session status: idle, working, waiting for input, waiting for permission
- Shows current tool or prompt context for each session
- Click to jump directly to the session's terminal
- Includes a TUI (`cctop`) for terminal-based monitoring

## Installation

### Homebrew

```bash
brew tap st0012/cctop
brew install --cask cctop
```

### Download manually

1. Download `cctop-macOS-arm64.zip` (Apple Silicon) or `cctop-macOS-x86_64.zip` (Intel) from the [latest release](https://github.com/st0012/cctop/releases/latest)
2. Unzip and move `cctop.app` to `/Applications/`
3. Right-click the app and select "Open" (required on first launch since the app is not notarized)

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
claude plugin add st0012/cctop
```

Restart any existing Claude Code sessions after installing the plugin.

### Build from source

Requires [Rust](https://rustup.rs/) and Xcode (for the menubar app).

```bash
# Install the Rust binaries (TUI + hook)
cargo install --path .

# Build the menubar app
xcodebuild build -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar -configuration Release -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
cp -R menubar/build/Build/Products/Release/CctopMenubar.app /Applications/
```

Run `cctop` for the TUI, or open `CctopMenubar.app` for the menubar app.

## How It Works

```
Claude Code  ──hook events──>  cctop-hook  ──JSON──>  ~/.cctop/sessions/
                                                             │
                                              ┌──────────────┤
                                              ▼              ▼
                                        Menubar app      TUI (cctop)
```

1. The cctop plugin registers hooks with Claude Code
2. Hooks fire on session events (start, prompt, tool use, stop, notifications)
3. `cctop-hook` writes session state as JSON to `~/.cctop/sessions/`
4. The menubar app and TUI watch these files and display live status

## Configuration

Create `~/.cctop/config.toml` to customize the editor used for "jump to session":

```toml
[editor]
process_name = "Code"      # or "Cursor", "Code - Insiders"
cli_command = "code"        # or "cursor", "code-insiders"
```

## TUI

The `cctop` command launches a terminal-based UI as an alternative to the menubar app.

![cctop TUI demo](docs/demo.gif)

```bash
cctop              # Launch TUI
cctop --list       # List sessions as text (no TUI)
```

| Key | Action |
|-----|--------|
| Up/Down or k/j | Navigate sessions |
| Enter | Jump to selected session |
| Right/Left | Detail view / back |
| r | Refresh |
| q, Esc, Ctrl+C | Quit |

## License

MIT
