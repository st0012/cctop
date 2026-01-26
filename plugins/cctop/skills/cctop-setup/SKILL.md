---
name: cctop-setup
description: Use when cctop-hook command fails or is not found. Installs the cctop Rust binaries via cargo.
---

# cctop Setup Skill

Installs the cctop binaries required for session monitoring.

## When to Use

**Run installation when:**
- Hook fails with "command not found: cctop-hook"
- User asks to set up cctop monitoring
- Session tracking is not working

## Installation

### Step 1: Check if Rust/Cargo is available

```bash
command -v cargo
```

If not found, inform user:
> Cargo (Rust package manager) is required. Install Rust from https://rustup.rs/

### Step 2: Install cctop

```bash
cargo install cctop
```

This installs two binaries to `~/.cargo/bin/`:
- `cctop` - TUI for monitoring sessions
- `cctop-hook` - Hook handler called by Claude Code

### Step 3: Verify installation

```bash
cctop-hook --version
```

### Step 4: Confirm PATH

Ensure `~/.cargo/bin` is in PATH. If commands still fail:

```bash
export PATH="$HOME/.cargo/bin:$PATH"
```

User should add this to their shell profile (~/.zshrc, ~/.bashrc).

## After Installation

The hooks registered by this plugin will now work. Session data will be written to `~/.cctop/sessions/` when Claude Code hooks fire.

User can run `cctop` in a separate terminal to monitor all active sessions.
