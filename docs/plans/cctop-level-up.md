# cctop Level-Up Plan

Consolidated improvement plan based on findings from UX design, Rust UI audit, Claude Code integration analysis, and macOS platform assessment.

## Core Insight

The #1 user need is passive notification: "Tell me when something needs me, without me having to check." Current cctop requires active checking (open TUI or click menubar). The improvements below are prioritized to close this gap.

## Status Model Expansion

The current 3-state model (`Idle`, `Working`, `NeedsAttention`) conflates two very different attention states. Expand to 4 states using the Status enum with `#[serde(other)]` for backwards and forwards compatibility:

```rust
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Idle,
    Working,
    WaitingPermission,   // CC blocked on permission approval (most urgent)
    WaitingInput,        // CC finished, waiting for new prompt
    #[serde(other)]
    NeedsAttention,      // Legacy fallback for any unknown variant, treated as WaitingInput
}
```

`#[serde(other)]` catches any unrecognized string during deserialization, handling both old files (`"needs_attention"`) and future unknown variants gracefully.

| Priority | Status | Color (menubar) | Color (TUI) | Signal |
|----------|--------|-----------------|-------------|--------|
| 1 | WaitingPermission | Red dot (pulsing) | Color::Red | PermissionRequest hook |
| 2 | WaitingInput | Amber dot (pulsing) | Color::Yellow | Notification(idle_prompt) |
| 3 | Working | Green dot | Color::Green | UserPromptSubmit, PreToolUse, PostToolUse |
| 4 | Idle | Gray dot | Color::DarkGray | SessionStart, Stop |

Old session files with `"needs_attention"` deserialize via the serde alias and are treated as `WaitingInput`.

## Session Struct Changes

Add 4 new fields to `Session`, all `#[serde(default)]` for backwards compatibility:

```rust
pub struct Session {
    // ... existing fields ...
    pub last_tool: Option<String>,            // "Bash", "Edit", etc. from PreToolUse
    pub last_tool_detail: Option<String>,     // command, file path, pattern, etc.
    pub notification_message: Option<String>, // from Notification/PermissionRequest
    pub context_compacted: bool,             // set by PreCompact(auto)
}
```

### State Transition Table

| Hook Event | status | last_tool | last_tool_detail | notification_message | context_compacted |
|---|---|---|---|---|---|
| SessionStart | Idle | CLEAR | CLEAR | CLEAR | CLEAR |
| UserPromptSubmit | Working | CLEAR | CLEAR | CLEAR | unchanged |
| PreToolUse | Working | SET | SET | unchanged | unchanged |
| PostToolUse | Working | unchanged | unchanged | unchanged | unchanged |
| PermissionRequest | WaitingPermission | CLEAR | CLEAR | SET | unchanged |
| Notification(idle_prompt) | WaitingInput | CLEAR | CLEAR | CLEAR | unchanged |
| Notification(permission_prompt) | WaitingPermission | CLEAR | CLEAR | no-overwrite | unchanged |
| Stop | Idle | CLEAR | CLEAR | CLEAR | unchanged |
| PreCompact(auto) | unchanged | unchanged | unchanged | unchanged | SET |

Rule: `last_tool` is only populated during Working status. Any transition away from Working clears it.

### Tool Detail Extraction

Extract `last_tool_detail` from the `tool_input` JSON in PreToolUse hooks:

| Tool | Extracted field | Example |
|------|----------------|---------|
| Bash | `tool_input.command` | `npm test` |
| Edit | `tool_input.file_path` | `/src/main.rs` |
| Write | `tool_input.file_path` | `/src/new_file.rs` |
| Read | `tool_input.file_path` | `/src/config.rs` |
| Grep | `tool_input.pattern` | `TODO` |
| Glob | `tool_input.pattern` | `**/*.ts` |
| WebFetch | `tool_input.url` | `https://docs.rs/...` |
| WebSearch | `tool_input.query` | `rust egui animation` |
| Task | `tool_input.description` | `Research auth patterns` |

### Tool Display Formatting

Shared `format_tool_display(tool, detail, max_len)` function in `session.rs`:

- Bash: `"Running: npm test"`
- Edit/Write/Read: `"Editing main.rs"` (extract filename from path)
- Grep: `"Searching: TODO"`
- Glob: `"Finding: **/*.ts"`
- Other: `"ToolName..."`

File paths use smart truncation (show filename, not path prefix). Commands truncate from the right.

## Hooks

Expand from 6 to 8 hooks in `hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [{"matcher": "startup|resume", "hooks": [{"type": "command", "command": "$HOME/.cargo/bin/cctop-hook SessionStart"}]}],
    "UserPromptSubmit": [{"matcher": ".*", "hooks": [{"type": "command", "command": "$HOME/.cargo/bin/cctop-hook UserPromptSubmit"}]}],
    "PreToolUse": [{"matcher": ".*", "hooks": [{"type": "command", "command": "$HOME/.cargo/bin/cctop-hook PreToolUse"}]}],
    "PostToolUse": [{"matcher": ".*", "hooks": [{"type": "command", "command": "$HOME/.cargo/bin/cctop-hook PostToolUse"}]}],
    "Stop": [{"matcher": ".*", "hooks": [{"type": "command", "command": "$HOME/.cargo/bin/cctop-hook Stop"}]}],
    "Notification": [{"matcher": ".*", "hooks": [{"type": "command", "command": "$HOME/.cargo/bin/cctop-hook Notification"}]}],
    "PermissionRequest": [{"matcher": ".*", "hooks": [{"type": "command", "command": "$HOME/.cargo/bin/cctop-hook PermissionRequest"}]}],
    "PreCompact": [{"matcher": "auto", "hooks": [{"type": "command", "command": "$HOME/.cargo/bin/cctop-hook PreCompact"}]}]
  }
}
```

Changes: Notification matcher expanded from `idle_prompt` to `.*`. PermissionRequest and PreCompact(auto) added.

### HookInput Struct Changes

```rust
struct HookInput {
    session_id: String,
    cwd: String,
    hook_event_name: String,
    #[serde(default)] transcript_path: Option<String>,
    #[serde(default)] prompt: Option<String>,
    #[serde(default)] tool_name: Option<String>,
    #[serde(default)] tool_input: Option<serde_json::Value>,  // NEW
    #[serde(default)] notification_type: Option<String>,
    #[serde(default)] message: Option<String>,                 // NEW
    #[serde(default)] title: Option<String>,                   // NEW
    #[serde(default)] trigger: Option<String>,                 // NEW (PreCompact)
    #[serde(default)] permission_mode: Option<String>,
}
```

### Hook Error Logging

Write errors to `~/.cctop/hook-errors.log` with timestamps. Cap at 1MB (truncate to last 500KB when exceeded). Format:

```
2026-02-07T13:45:00Z [PostToolUse] Error: failed to parse JSON: unexpected token
```

---

## Phase 1: Core UX (no architecture changes)

### 1.1 Menubar Popup: Show Prompt, Time, Variable Row Height

**Files**: `src/menubar/popup.rs`

Add last_prompt (truncated, ~40 chars) and relative time to popup rows. Use variable row heights:

```
WaitingPermission (62px):
  [red dot]    api-server                30s ago
               feature/oauth
               Permission needed: Bash command

WaitingInput (62px):
  [amber dot]  frontend-app              5m ago
               fix/login
               "Add error handling to the login form"

Working (62px):
  [green dot]  data-pipeline             12s ago
               refactor
               Running: npm test

Idle (44px):
  [gray dot]   docs-site                 1h ago
               main
```

Line 3 source by status:
- WaitingPermission: `notification_message`
- WaitingInput: `last_prompt` (in quotes)
- Working: `format_tool_display(last_tool, last_tool_detail)`, fallback to `last_prompt`
- Idle: no line 3

Height constants:
- `ROW_HEIGHT_WITH_CONTEXT = 62.0` (3-line rows)
- `ROW_HEIGHT_MINIMAL = 44.0` (idle, 2-line rows)
- `calculate_popup_height` sums per-row heights instead of flat multiply

Time display: right-aligned `format_relative_time()` at `(row_rect.max.x - 16.0, row_rect.min.y + 10.0)` in `egui::FontId::proportional(11.0)`.

### 1.2 Menubar Popup: Scroll for Many Sessions

**Files**: `src/menubar/popup.rs`

- `MAX_POPUP_HEIGHT = 500.0` (fits ~8 session rows)
- Wrap session sections in `egui::ScrollArea::vertical().max_height(...)`
- Quit row stays outside scroll area (always visible)
- egui provides auto-hiding scrollbar

### 1.3 Menubar Popup: Needs Attention Emphasis

**Files**: `src/menubar/popup.rs`

- Section headers for WaitingPermission: red text (`STATUS_RED`)
- Section headers for WaitingInput: amber text (`STATUS_AMBER`)
- Pulsing dots for attention states: 1-2 second cycle, 60%-100% opacity via `ctx.input(|i| i.time)` sine wave
- Only request continuous repaints when attention sessions exist AND popup is visible
- Subtle background tint on attention sections: `Color32::from_rgba_unmultiplied(245, 158, 11, 13)` (~5% opacity)

Color constant to add:
```rust
pub const STATUS_RED: Color32 = Color32::from_rgb(239, 68, 68);
```

### 1.4 Menubar Popup: Dismiss on Focus Loss

**Files**: `src/menubar/app.rs`

Handle `WindowEvent::Focused(false)` to hide popup. Add 200ms debounce after tray clicks to prevent the popup from immediately closing when opened via tray icon.

### 1.5 Dynamic Tray Icon

**Files**: `src/menubar/app.rs`, `assets/tray-icon.png`, `assets/tray-icon-attention.png`

Replace "CC" text with template icons:
- Normal: `>_` terminal prompt icon (22x22pt / 44x44px @2x, black on transparent, 2px line weight)
- Attention: `>!` variant (same specs, exclamation replaces underscore)

Icon swap + title text for status:
```rust
if any_waiting_permission { set_icon(attention); set_title(Some("!")); }
else if any_waiting_input  { set_icon(attention); set_title(Some("*")); }
else                       { set_icon(normal);    set_title(None); }
```

Requires moving tray_icon into `MenubarApp` struct (currently in separate RefCell). Embed icons via `include_bytes!`.

### 1.6 TUI Color Alignment

**Files**: `src/tui.rs`

Change TUI colors to match menubar semantics:
- `Color::Yellow` -> `Color::Rgb(245, 158, 11)` (amber, WaitingInput)
- `Color::Cyan` -> `Color::Rgb(34, 197, 94)` (green, Working)
- Add `Color::Rgb(239, 68, 68)` (red, WaitingPermission)
- Keep `Color::DarkGray` for Idle

4 section headers: "WAITING FOR PERMISSION" / "WAITING FOR INPUT" / "WORKING" / "IDLE"

### 1.7 TUI File Watcher

**Files**: `src/tui.rs`

Replace 2-second polling with `SessionWatcher` from `watcher.rs` (already used by menubar). Check `watcher.poll_changes()` in the 50ms event loop tick. Keep 30-second liveness check. Reduces perceived latency from ~2s to <100ms.

### 1.8 TUI Empty State

**Files**: `src/tui.rs`

```
No active sessions

Install the cctop plugin: claude plugin install cctop
Then restart your Claude Code sessions.

Tip: Run cctop-menubar for always-on monitoring.
```

### 1.9 Hook Error Logging

**Files**: `src/bin/cctop_hook.rs`

Append errors to `~/.cctop/hook-errors.log` with timestamps. Cap at 1MB.

---

## Phase 2: Enhanced Data (data model changes)

### 2.1 Session Struct: New Fields

**Files**: `src/session.rs`, `src/bin/cctop_hook.rs`

Add `last_tool`, `last_tool_detail`, `notification_message`, `context_compacted` to Session. Add `tool_input`, `message`, `title`, `trigger` to HookInput. Implement tool detail extraction and state transition clearing logic per the table above.

### 2.2 Status Enum Expansion

**Files**: `src/session.rs`, all UI files

Add `WaitingPermission`, `WaitingInput`, legacy `NeedsAttention` with `#[serde(alias)]`. Update `GroupedSessions` to 4 groups. Update all match arms.

### 2.3 PermissionRequest + PreCompact Hooks

**Files**: `plugins/cctop/hooks/hooks.json`, `src/bin/cctop_hook.rs`

Add PermissionRequest (sets WaitingPermission + notification_message from tool details) and PreCompact(auto) (sets context_compacted flag). Expand Notification matcher to `.*`.

### 2.4 PostToolUse Write Optimization

**Files**: `src/bin/cctop_hook.rs`

Skip file write on PostToolUse when status is already Working and no fields changed. Reduces file I/O on every tool call.

### 2.5 Context Compaction Warning

**Files**: `src/menubar/popup.rs`, `src/tui.rs`

When `context_compacted == true`, show a small warning indicator on the session row. Clear on SessionStart.

---

## Phase 3: Distribution & Polish

### 3.1 macOS .app Bundle

Package `cctop-menubar` as a proper macOS .app with:
- `Info.plist` (LSUIElement=true, bundle identifier)
- `AppIcon.icns` (1024x1024 master, all standard sizes)
- Code signing (needed for notifications)

### 3.2 macOS Notifications

**Requires**: .app bundle + code signing

Use `UNUserNotificationCenter` to fire native notifications on WaitingPermission transitions. Include "Focus Session" action button. Configuration:

```toml
[notifications]
enabled = true
sound = false
permission_only = false  # only notify for permission prompts
```

### 3.3 Launch at Login

**Files**: `src/bin/cctop_menubar.rs`

CLI flags:
- `--install-launch-agent` writes `~/Library/LaunchAgents/com.st0012.cctop.plist`
- `--uninstall-launch-agent` removes it
- `--launch-agent-status` prints current state

Store `shown_login_tip` flag in `~/.cctop/config.toml` under `[ui]`.

### 3.4 Homebrew Distribution

Personal tap (`homebrew-cctop`) with formula building from source:
```ruby
class Cctop < Formula
  desc "Monitor Claude Code sessions across workspaces"
  homepage "https://github.com/st0012/cctop"
  url "https://github.com/st0012/cctop/archive/refs/tags/v0.1.0.tar.gz"
  depends_on "rust" => :build
  def install
    system "cargo", "install", *std_cargo_args
  end
end
```

Install: `brew install st0012/cctop/cctop`

Homebrew cask with pre-built .app comes later after .app bundle is stable.

### 3.5 First-Launch Experience

- Menubar shows `>_` icon, popup shows "No active sessions" with help text: "Install the cctop plugin in Claude Code to start monitoring."
- Help text disappears once sessions appear
- After 5+ launches, show one-time tip about Launch at Login
- No wizard, no modal, no multi-step setup
- If running from .app bundle, silently ensure cctop-hook symlink exists

---

## Testing the macOS App Locally

### Prerequisites

- macOS 13.0+ (Ventura or later)
- Rust toolchain installed (`rustup.rs`)
- The project cloned locally

### 1. Build and Create the .app Bundle

```bash
# Full build + bundle (from project root)
./scripts/bundle-macos.sh

# Or if you already ran `cargo build --release`:
./scripts/bundle-macos.sh --skip-build
```

Output: `dist/cctop.app` (~7.7MB total)

The script:
- Runs `cargo build --release` (unless `--skip-build`)
- Creates `dist/cctop.app/Contents/` with Info.plist, MacOS/, Resources/
- Copies `cctop-menubar` and `cctop-hook` into the bundle
- Strips debug symbols
- Ad-hoc signs the bundle (needed for arm64 macOS)

### 2. Launch and Verify

```bash
# Launch the .app
open dist/cctop.app

# Verify it's running (should show process from the bundle path)
ps aux | grep cctop-menubar | grep -v grep

# You should see "CC" appear in the macOS menu bar
# Click it to open the popup
```

To test with session data:

```bash
# Create mock sessions
./scripts/demo-setup.sh

# Click the "CC" tray icon - you should see 5 sessions
# (1 needs attention, 2 working, 2 idle)

# Clean up mock sessions
./scripts/demo-cleanup.sh
```

To stop the app:

```bash
# Click the tray icon, then click "Quit cctop" in the popup
# Or:
pkill -f "dist/cctop.app/Contents/MacOS/cctop-menubar"
```

### 3. Install to /Applications (Optional)

```bash
# Copy to Applications
cp -r dist/cctop.app /Applications/

# Launch from Applications
open /Applications/cctop.app
```

Since the app is ad-hoc signed (not notarized), macOS may block it on first launch. To bypass:
1. Right-click the app in Finder and select "Open"
2. Or: System Settings > Privacy & Security > scroll down > click "Open Anyway"

This only needs to be done once.

### 4. Create a Distribution Zip

```bash
cd dist
zip -r cctop-macOS-arm64.zip cctop.app
ls -lh cctop-macOS-arm64.zip  # ~3-4MB compressed
```

### 5. Testing the GitHub Actions Workflow

The workflow at `.github/workflows/release.yml` triggers on tag pushes (`v*`). To test it:

```bash
# Option A: Push a test tag (will create a real GitHub release)
git tag v0.1.0-test
git push origin v0.1.0-test

# Check the Actions tab on GitHub for build status
# Delete the test tag and release when done:
git tag -d v0.1.0-test
git push origin :refs/tags/v0.1.0-test
```

To test the workflow locally without pushing, use [act](https://github.com/nektos/act):

```bash
brew install act

# Dry run (won't actually create a release)
act push --tag v0.1.0-test --dryrun

# Note: act has limited macOS runner support.
# For full testing, push a tag to trigger the real workflow.
```

### 6. Verify Bundle Contents

```bash
# Check Info.plist
plutil -p dist/cctop.app/Contents/Info.plist

# Expected output includes:
#   "LSUIElement" => 1          (no dock icon)
#   "CFBundleExecutable" => "cctop-menubar"
#   "CFBundleIdentifier" => "com.st0012.cctop"

# Check binaries
file dist/cctop.app/Contents/MacOS/cctop-menubar
# Should show: Mach-O 64-bit executable arm64

# Check code signature
codesign -dvvv dist/cctop.app 2>&1 | grep "Signature"
# Should show: Signature=adhoc
```

### Gotchas

- **Two menubar instances**: If you already have `cctop-menubar` running (e.g., from `cargo install`), you'll see two "CC" icons in the menu bar. Kill the old one first: `pkill cctop-menubar`
- **Session data is shared**: Both the .app and `cargo install` versions read from the same `~/.cctop/sessions/` directory. They don't conflict but you'll see the same data in both.
- **Bundle is not notarized**: The ad-hoc signature works locally but other users will need to bypass Gatekeeper on first launch (see step 3 above).
- **Stripping removes debug info**: If you need to debug a crash in the bundled app, use the unstripped binary at `target/release/cctop-menubar` instead.
- **Cross-compilation**: To build for Intel Macs from Apple Silicon: `./scripts/bundle-macos.sh --target x86_64-apple-darwin` (requires the x86_64 Rust target: `rustup target add x86_64-apple-darwin`).

---

## Deferred (Not in Scope)

These were evaluated and deliberately excluded to keep the tool focused on "what needs me now?":

- **Cost tracking**: Not actionable from a monitoring tool. Better suited for analytics.
- **Tool usage statistics / sparklines**: Adds complexity without helping prioritization.
- **Error rate badges**: Tool errors are normal in CC workflows; showing them creates false alarms.
- **Subagent indicators**: Nice for power users but adds visual noise. Maybe in TUI detail view later.
- **Prompt history**: Last prompt is sufficient. Full history needs its own UI.
- **Keyboard navigation in menubar popup**: Keep popup mouse-first. TUI is the keyboard surface.
- **Spotlight integration**: Insufficient value for the complexity.

---

## Files Changed Summary

| File | Phase | Changes |
|------|-------|---------|
| `src/session.rs` | 1+2 | 4 new Session fields, Status enum expansion, GroupedSessions 4 groups, `format_tool_display()` |
| `src/menubar/popup.rs` | 1 | Variable row heights, 4 sections, prompt+time display, scroll, pulsing dots, STATUS_RED |
| `src/menubar/app.rs` | 1 | Focus-loss dismiss, tray icon swap, move tray_icon into struct |
| `src/tui.rs` | 1 | Color alignment, 4 sections, file watcher, empty state, responsive columns |
| `src/bin/cctop_hook.rs` | 1+2 | Tool detail extraction, state transitions, PermissionRequest/PreCompact handling, error logging |
| `plugins/cctop/hooks/hooks.json` | 2 | Add PermissionRequest, PreCompact; expand Notification matcher |
| `src/bin/cctop_menubar.rs` | 3 | Launch agent CLI flags |
| `src/config.rs` | 3 | Notification config, `[ui]` section |
| `src/main.rs` | 1 | Updated `--list` output for 4 groups |
| `assets/tray-icon.png` | 1 | New: normal template icon |
| `assets/tray-icon-attention.png` | 1 | New: attention template icon |
