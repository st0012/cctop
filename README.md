# cctop

A TUI for monitoring Claude Code sessions across workspaces.

![Demo](docs/demo.gif)

## Features

- Monitor multiple Claude Code sessions in real-time
- See status at a glance: idle, working, needs attention
- Jump directly to any session with Enter

## Installation

Requires [Rust](https://rustup.rs/) to be installed.

```bash
cargo install cctop
```

Then install the Claude Code plugin to enable session tracking:

```bash
claude plugin add st0012/cctop
```

**Important:** The plugin uses hooks to track session activity. Only sessions started *after* installing the plugin will be tracked. Restart any existing Claude Code sessions to begin tracking them.

## Usage

Run `cctop` in a separate terminal while Claude Code sessions are active.

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Up/Down or k/j | Navigate sessions |
| Enter | Jump to selected session |
| r | Refresh |
| q, Esc, Ctrl+C | Quit |

### CLI Options

```bash
cctop              # Launch TUI
cctop --list       # List sessions as text (no TUI)
cctop --cleanup-stale  # Remove stale session files
cctop --version    # Print version
```

## Configuration

Create `~/.cctop/config.toml` to customize behavior:

```toml
[editor]
process_name = "Code"      # or "Cursor"
cli_command = "code"       # or "cursor"
```

## How It Works

1. The cctop plugin registers hooks with Claude Code
2. Hooks fire on session events (start, prompt, tool use, stop, end)
3. `cctop-hook` writes session state to `~/.cctop/sessions/`
4. The cctop TUI polls these files and displays status

## License

MIT
