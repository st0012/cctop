# AGENTS.md - Development Guide for cctop

## Project Overview

This file is the canonical guide for agents helping develop cctop. cctop itself is a macOS menubar app for monitoring AI coding sessions across workspaces; it tracks session status through client integrations and allows jumping to sessions.

## MUST FOLLOW: Development Principles

- Do NOT modify the user's tool configuration without explicit consent (e.g. installing plugins, editing hooks or settings files)
- Do NOT make breaking changes that require users to restart running sessions to reconnect to the app
  - Newly added features being unavailable until restart is acceptable
- Treat persisted session state as the source of truth when debugging lifecycle bugs. UI screenshots are symptoms; `~/.cctop/sessions/*.json`, `~/.cctop/logs/`, and client app state are evidence.
- Keep lifecycle concepts separate: app liveness, client process liveness, session visibility, archive/hidden/subagent classification, and hook writer provenance are different layers.
- When changing a shared source of truth such as hook version, session schema, or install path, update the release/install tooling in the same change and verify it.

## Agent Workflow

- Work from latest `origin/master` before starting a new cctop change.
- Prefer small, reviewable changes. Do not bundle unrelated lifecycle, UI, release, and documentation work unless the user asks for one PR.
- For non-trivial work, use a teammate/navigator agent only when the active development environment explicitly provides that capability. This refers to development workflow, not cctop-tracked product agents or subagents. Keep the navigator read-only unless there is a clearly separated write scope.
- Be proactive with review feedback: for PRs you are actively maintaining, if there is exactly one clear, low-risk, actionable review comment, implement it locally, run focused verification, and push when authorized to update the PR. Do not wait for the user to repeat the request.
- Never reply to GitHub PR comments or issues, and do not resolve GitHub review threads. Leave GitHub conversation actions to the developer.
- Do not commit temporary explanation artifacts, local investigation HTML, screenshots, scratch scripts, or generated debugging files unless they are intentional product/docs assets.
- Keep canonical agent guidance in this file. Pointer files such as `CLAUDE.md` should redirect here instead of duplicating instructions that will drift.

## PR Standards

- PR titles must be plain human-readable titles. Never prefix them with `[codex]`, tool names, or agent tags.
- PR descriptions must explain the problem first, then the solution, then verification. Do not lead with a change inventory alone.
- Use explicit `Problem`, `Solution`, and `Verification` sections for agent-authored PRs unless the developer asks for a different format.
- Every factual claim in a PR description should be verified from the repo, docs, release notes, or the actual diff.
- Before calling a PR final, check the remote PR title, body, changed files, review threads, CI/relevant tests, and local `git diff --name-status origin/master...HEAD`.

## Session Debugging Rules

- For wrong source, wrong grouping, stale status, duplicate display, or unexpected dormant/idle behavior, inspect the session JSON before changing display logic.
- `created_by_hook_version` missing or null on a file that should have been created by hook `0.16.0+` is strong evidence of a pre-metadata or stale hook writer.
- `last_written_by_hook_version` tells you the latest hook that touched the file, not necessarily the original creator.
- For explicit non-desktop harnesses such as `opencode` and `pi`, do not classify inherited Claude/Codex Desktop `terminal.bundle_id` values as desktop proof. Treat those bundle IDs as leaked launcher environment unless the harness is desktop-compatible or missing.
- If hook provenance is current, inspect resolved harness/source, client event delivery/logs, PID/app liveness, and visibility/lifecycle classification as relevant to the symptom.
- Apply lifecycle and hook fixes consistently across all supported clients unless the problem is explicitly client-specific.

## Architecture

```
cctop/
├── menubar/           # Swift/SwiftUI app (menubar + hook CLI)
│   ├── CctopMenubar.xcodeproj/
│   ├── CctopMenubar/
│   │   ├── CctopApp.swift         # App entry point
│   │   ├── AppDelegate.swift      # NSStatusItem + FloatingPanel toggle
│   │   ├── FloatingPanel.swift    # NSPanel subclass (stays open)
│   │   ├── Models/                # Session, SessionStatus, HookEvent, Config (shared)
│   │   ├── Views/                 # PopupView, SessionCardView, QuitButton, etc.
│   │   ├── Services/              # SessionManager, FocusTerminal
│   │   └── Hook/                  # cctop-hook CLI target only
│   │       ├── HookMain.swift     # CLI entry point (stdin, args, dispatch)
│   │       ├── HookInput.swift    # Codable struct for cctop-hook input JSON from all integrations
│   │       ├── HookHandler.swift       # Core logic (transitions, cleanup, PID)
│   │       ├── SessionNameLookup.swift # Session name from transcript/index
│   │       └── HookLogger.swift        # Per-session logging
│   └── CctopMenubarTests/
├── plugins/cctop/     # Claude Code plugin
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json
│   └── skills/cctop-setup/SKILL.md
├── plugins/opencode/  # opencode plugin (JS, translates events to cctop-hook calls)
│   ├── plugin.js      # Event handler, calls cctop-hook binary
│   ├── package.json   # Plugin manifest and node:test script
│   └── test/          # node:test coverage for opencode event translation
├── plugins/pi/        # pi coding agent extension (TS, translates events to cctop-hook calls)
│   └── cctop.ts       # Extension entry point, calls cctop-hook binary
├── scripts/
│   ├── bundle-macos.sh        # Build and bundle .app
│   ├── sign-and-notarize.sh   # Code sign + Apple notarization
│   ├── generate-appcast.sh    # Sparkle appcast (multi-arch)
│   ├── bump-version.sh        # Version bumper (project, hook, plugin, packaging, site fallback)
│   └── render-og.sh           # Render site/og.html → site/og.png (1200x630)
├── site/                # Public website (cctop.app)
│   ├── index.html       # Single static page, no build step
│   └── README.md        # Local preview + sync rules
├── .github/workflows/
│   └── pages.yml        # Auto-deploys site/ to GitHub Pages on push to master
├── packaging/
│   └── homebrew-cask.rb  # Homebrew cask template
└── .claude-plugin/
    └── marketplace.json  # For local plugin installation
```

### Swift Menubar App

The macOS menubar app is built with Swift/SwiftUI. It uses a custom `AppDelegate` with `NSStatusItem` and a `FloatingPanel` (NSPanel subclass) that stays open until the user clicks the menubar icon again.

**Location:** `menubar/`

**Build:**
```bash
# Build from command line
xcodebuild build -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar -configuration Debug -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"

# Run the app
open menubar/build/Build/Products/Debug/CctopMenubar.app

# Run tests
xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar -configuration Debug -derivedDataPath menubar/build/
```

**Visual verification:** Open the Xcode project and use SwiftUI Previews (Canvas) for instant visual feedback. All views have `#Preview` blocks with mock data.

**Data flow:** The menubar app reads `~/.cctop/sessions/*.json` files. These are written by `cctop-hook` (Swift CLI), which is called by the supported client integrations (Claude Code hooks, opencode JS plugin, pi TS extension, and Codex CLI hooks + shim). Both Xcode targets share model code.

### Website (`site/`)

The public site at https://cctop.app lives in `site/index.html` — a single static page with no build step. Pushed to master, `.github/workflows/pages.yml` uploads `site/` as the GitHub Pages artifact and deploys.

**One-time repo settings:**
1. Settings > Pages > Source = "GitHub Actions".
2. Settings > Pages > Custom domain = `cctop.app`. The `site/CNAME` file pins this on every deploy — without it, the artifact upload would clear the custom domain on each run.
3. After the Let's Encrypt cert provisions, check "Enforce HTTPS". `.app` is HSTS preloaded, so HTTPS is mandatory.

**Local preview:**
```bash
python3 -m http.server 8000 --directory site
```

**What the site auto-syncs from the repo (no manual edit needed):**
- Hero badge version — a small `fetch()` to the GitHub releases API overrides the static fallback at page load. The static fallback is bumped by `scripts/bump-version.sh`.
- Screenshots — referenced via `https://raw.githubusercontent.com/st0012/cctop/master/docs/...`, so updating `docs/*.png` or `docs/*.gif` propagates to the site automatically.
- DMG download links — use the `releases/latest/download/...` redirect, so they always point at the newest release.

**What you must manually keep in sync when changing the implementation:**
- README "Supported Tools" table → site `#tools` "Coding agents" cards (name + URL)
- README "Supported Editors & Terminals" tiers → site `#tools` "Editors & terminals" subgroups (the three tiers: targets pane / opens project / activates app)
- Color theme list (`Color+Theme.swift`, README themes table) → site `#themes` cards (name, accent hex swatch, screenshot filename)
- README FAQ → site `#faq` `<details>` entries
- Hero / install / privacy copy if the README's framing changes

`site/README.md` has the same sync table for quick reference when working in the site folder.

**Social preview card (`site/og.html` → `site/og.png`):**

The social preview is a static HTML source rendered to a 1200×630 PNG and committed alongside it. The site's `og:image` meta tag points at `https://cctop.app/og.png`.

**ALWAYS** re-run `scripts/render-og.sh` after editing `site/og.html`, and commit `site/og.png` in the same commit. Otherwise the deployed `og:image` and the source diverge — link unfurlers (Twitter, Slack, Discord) cache OG images aggressively, so a stale PNG can persist for days even after the source change ships.

```bash
scripts/render-og.sh   # writes site/og.png from site/og.html
```

The script uses Chrome headless (auto-detected on macOS, override with `CHROME_BIN=...`). It validates the output is exactly 1200×630 and exits non-zero if rendering fails. The script is also safe to re-run — it always overwrites the existing PNG.

## Supported Client Integrations

| Client / host | Supported | Hook path | Identity and file key | Lifecycle / visibility notes |
|-------|-----------|-------------|---------|-----------------|
| Claude Code | Yes | Claude plugin shell hooks → `run-hook.sh` → `cctop-hook --harness cc` | `source: "cc"`; PID-keyed `<pid>.json`; active plugin version lives under `~/.claude/plugins/cache/cctop/cctop/<version>/` with `.claude-plugin/plugin.json` and no `.orphaned_at` | Terminal/editor host uses PID + process-start-time liveness; finished sessions are archived into Recent Projects and removed |
| Claude Desktop | Yes | Same Claude plugin hook path, hosted by the Claude Desktop app | `source: "cc"` plus trusted bundle ID `com.anthropic.claudefordesktop`; PID-keyed file; title/archive metadata read from `~/Library/Application Support/Claude/claude-code-sessions` | Desktop app liveness applies unless `ended_at` is set; disconnected sessions stay dormant during retention; archived/orphaned metadata filters visibility; no deep link, so jump-to-session activates the app |
| Codex CLI | Yes | `~/.codex/hooks.json` → `~/.codex/cctop-shim.sh` → `cctop-hook --harness codex` | `source: "codex"`; session-id-keyed `codex-<session_id>.json` because one host PID can emit multiple conversations | Uses session ID for display/dedup; subagent ownership from `~/.codex/state_5.sqlite` hides subagent-owned sessions |
| Codex Desktop | Yes | Same Codex hook shim path, hosted by the Codex Desktop app | `source: "codex"` plus trusted bundle ID `com.openai.codex`; session-id-keyed `codex-<session_id>.json`; titles read from `~/.codex/session_index.jsonl` | Desktop app liveness/recency applies unless `ended_at` is set; disconnected sessions stay dormant during retention; archived/subagent-owned threads from `~/.codex/state_5.sqlite` filter visibility; memory/title helper sessions auto-hide; deep links use `codex://threads/<uuid>` |
| opencode | Yes | JS plugin → `cctop-hook` CLI via `execFileSync` | `source: "opencode"`; PID-keyed `<pid>.json`; installed at `~/.config/opencode/plugins/cctop.js`; explicit source wins over inherited Claude/Codex Desktop bundle IDs | Plugin load and `session.created` start tracking; PID liveness decides finished state |
| pi | Yes | TS extension → `cctop-hook` CLI via `execFileSync` | `source: "pi"`; PID-keyed `<pid>.json`; installed at `~/.pi/agent/extensions/cctop.ts`; explicit source wins over inherited Claude/Codex Desktop bundle IDs | Skips non-interactive sessions (`ctx.hasUI === false`); `session_shutdown` sends `SessionEnd`; PID liveness decides finished state |
| Aider | No | — | — | — |
| Goose | No | — | — | — |
| Amp | No | — | — | — |

For detailed lifecycle and persistence rules, see [Session Status Logic](#session-status-logic), [Session File Format](#session-file-format), and [`docs/session-files.md`](docs/session-files.md). Keep this table as the quick integration map.

### How each integration works

- **Claude Code**: Fires shell hooks on lifecycle events. A shell shim (`run-hook.sh`) dispatches to `cctop-hook`, a Swift CLI bundled in the app. `cctop-hook` reads JSON from stdin, applies status transitions, and writes `~/.cctop/sessions/{pid}.json`. Installed via `claude plugin marketplace add st0012/cctop && claude plugin install cctop`.
- **opencode**: Runs a JS plugin in-process (Bun). The plugin translates opencode events to `cctop-hook` calls via `execFileSync`. Installed via the app UI (copies bundled plugin to opencode's plugins dir).
- **pi**: Runs a TS extension in-process (Node.js via jiti). The extension translates pi events to `cctop-hook` calls via `execFileSync`. Skips non-interactive sessions (`ctx.hasUI === false`) to avoid tracking background agents. Installed via the app UI (copies bundled extension to pi's extensions dir).
- **Codex CLI**: Uses Codex's lifecycle hooks system (feature flag `[features].hooks` in `~/.codex/config.toml`, default-true). cctop writes a shell shim to `~/.codex/cctop-shim.sh` and merges five hook entries into `~/.codex/hooks.json` (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop). config.toml is only patched when there's something to fix: (a) strip any `codex_hooks` line, which triggers Codex's startup warning whenever loaded; (b) override an explicit `hooks = false` opt-out so the install actually fires. Remove also migrates a lingering `codex_hooks` key, but value-preservingly (an opt-out is renamed to `hooks = false`, never re-enabled), and the Settings row offers a standalone "Clean Up" for a stray key with nothing installed. The "Update Available" tile in Settings surfaces any pending patch so the user opts in with a click rather than having cctop edit their config silently. `isInstalled()` treats an unset flag as installed (Codex default) — only an explicit opt-out under `[features]` counts as not installed. Each installed hook invokes `~/.codex/cctop-shim.sh <Event>`, which execs `cctop-hook <Event> --harness codex`. Installed hook files alone do not mean hooks run: Codex only executes hooks the user has reviewed and trusted, recording each approval under `[hooks.state."<hooks.json path>:<event>:..."]` with a `trusted_hash` in config.toml. cctop reads those entries as a UI signal only (it never writes them and never reproduces Codex's trust hash) and `CodexIntegrationManager` derives a `CodexHookStatus` (not installed / hooks disabled / needs update / installed-untrusted / trusted); the UI shows a "Trust Hooks" walkthrough instead of a connected badge until all five registered events are trusted. The only trust UI Codex provides is the CLI's startup "Hooks need review" prompt (`tui/src/startup_hooks_review.rs`; there is no `/hooks` slash command, and Codex Desktop has no hook-review UI at all — verified empirically on 0.137.0), so the walkthrough sends users to a new Codex CLI session and notes that Desktop shares the resulting trust state. The match is per hooks.json path + event and ignores the matcher/hook indices in the key, so trust granted to user-owned entries in the same file can read as trusted while cctop's own entries are still pending — accepted imprecision; do not "fix" it by reimplementing Codex's private hash.

All paths converge at `~/.cctop/sessions/*.json` — the menubar app watches this directory and renders sessions regardless of source. Each client identifies itself via `harness_name` in the hook input (JSON field for opencode/pi, `--harness` CLI arg for Claude Code and Codex). The session JSON file still uses the `source` key for the harness name (MIGRATION(harness_name) tracks the eventual rename).

Hook writer metadata starts with the hook version that introduced it (`0.16.0`). New files written by metadata-aware hooks include `created_by_hook_version`; each write refreshes `last_written_by_hook_version`. Do not backfill `created_by_hook_version` on legacy files, because the true creator is unknown. If `created_by_hook_version` is missing or null on a file that should have been created by `0.16.0+`, treat it as strong evidence that an outdated/pre-metadata hook created the file and inspect the app-owned hook install path before changing UI classification logic.

## Key Components

### Binaries
- `CctopMenubar.app` - macOS menubar app (Swift/SwiftUI, built via Xcode)
- `cctop-hook` - Hook handler called by all plugins (Swift CLI, Xcode target in same project)
- `plugins/opencode/plugin.js` - opencode plugin (JS, translates events to cctop-hook calls)
- `plugins/pi/cctop.ts` - pi coding agent extension (TS, maps events to cctop-hook calls)
- `plugins/codex/hooks.json` + `plugins/codex/cctop-shim.sh` - Codex CLI plugin (hooks.json template + shell shim)

### Data Flow

All supported clients use `cctop-hook` as the single entry point for session state management. Each plugin or hook shim translates client-specific events into hook calls.

**Claude Code path:**
1. Claude Code fires hooks (SessionStart, UserPromptSubmit, Stop, etc.)
2. `run-hook.sh` (shell shim) dispatches to `cctop-hook` (Swift CLI)
3. `cctop-hook` writes session files to `~/.cctop/sessions/`

**opencode path:**
1. opencode fires plugin events (session.created, chat.message, tool.execute.before, etc.)
2. `plugin.js` translates events to hook calls and invokes `cctop-hook` via `execFileSync`
3. `cctop-hook` writes session files to `~/.cctop/sessions/`

**pi path:**
1. pi fires extension events (session_start, input, tool_execution_start, etc.)
2. `cctop.ts` translates events to hook calls and invokes `cctop-hook` via `execFileSync`
3. `cctop-hook` writes session files to `~/.cctop/sessions/`
4. Non-interactive sessions (`ctx.hasUI === false`) are skipped entirely

**Codex CLI path:**
1. Codex fires lifecycle hook commands from `~/.codex/hooks.json`
2. `cctop-shim.sh` dispatches to `cctop-hook <Event> --harness codex`
3. `cctop-hook` writes session files to `~/.cctop/sessions/`

**All paths converge:** The menubar app (SessionManager file watcher) reads `~/.cctop/sessions/*.json` and displays live status regardless of source. Sessions include a `source` field identifying the harness (`"cc"` for Claude Code, `"opencode"` for opencode, `"pi"`, `"codex"`). Most integrations write PID-keyed files (`<pid>.json`); Codex writes `codex-<session_id>.json` because multiple conversations can share one host PID.

## Development Commands

```bash
# Build both targets (menubar app + cctop-hook CLI)
make build

# Run all tests (OpenCode plugin node:test suite + Swift tests)
make test

# Lint with swiftlint --strict
make lint

# Validate the hook input contract against fixtures, Swift parsing, and plugins
make contract

# Lint + contract validation + build + test (default)
make all

# Build and open the menubar app
make run

# Install cctop-hook to ~/.cctop/bin/ (Release build)
make install

# Clean build artifacts
make clean

# Check a specific session file
cat ~/.cctop/sessions/<pid>.json | jq '.'

# Bump version (updates pbxproj, plugin JSON, cask, etc.)
scripts/bump-version.sh 0.3.0

# Build release .app bundle
scripts/bundle-macos.sh
```

**IMPORTANT:** Always use `scripts/bump-version.sh <version>` to bump versions. Never edit version numbers manually — the script updates versioned files including the Xcode project, `Config.hookVersion`, plugin manifests, packaging, and the site fallback badge.

### Hook Contract Validation

Use `make contract` as the single validation entry point for hook contract work. It runs the fixture schema checks and hook/plugin drift checks together. Treat `scripts/validate-fixtures.sh`, `scripts/validate-hooks-coverage.sh`, and `scripts/validate-hook-contract.py` as implementation details or narrower debugging tools, not as separate commands agents need to remember for normal verification.

### Linting

The project uses [SwiftLint](https://github.com/realm/SwiftLint) in strict mode. Run `make lint` before committing. Common issues:
- **Line length**: Max 150 characters. Break long lines (especially in `Session+Mock.swift` mock arrays).
- A Claude Code hook in `.claude/settings.json` auto-runs swiftlint on every file edit, but always verify with `make lint` before committing.

### Visual Changes
- Use Xcode Previews (Canvas) for instant visual feedback on any SwiftUI view
- All views have `#Preview` blocks with mock data for different states

## Testing the Hooks

```bash
# Manually trigger a hook to create/update a session
echo '{"session_id":"test123","cwd":"/tmp","hook_event_name":"SessionStart"}' | /Applications/cctop.app/Contents/MacOS/cctop-hook SessionStart

# Or use the debug build
echo '{"session_id":"test123","cwd":"/tmp","hook_event_name":"SessionStart"}' | menubar/build/Build/Products/Debug/cctop-hook SessionStart

# Check if session was created. Non-Codex files are usually PID-keyed.
cat ~/.cctop/sessions/*.json | jq 'select(.session_id=="test123")'

# Clean up test session
for f in "$HOME"/.cctop/sessions/*.json; do
  [ -e "$f" ] || continue
  jq -e 'select(.session_id=="test123")' "$f" >/dev/null && rm "$f"
done
```

## Testing the opencode Plugin

The opencode plugin (`plugins/opencode/plugin.js`) is installed via the menubar app when the user clicks "Install Plugin" in Settings > Monitored Tools or via the install banner that appears when opencode is detected (`~/.config/opencode/` exists). The bundled plugin is copied to `~/.config/opencode/plugins/cctop.js`.

Automated plugin tests live under `plugins/opencode/test/` and use Node's built-in `node:test` runner. Run them directly when changing `plugins/opencode/plugin.js`:

```bash
npm --prefix plugins/opencode test
```

`make test` runs the opencode plugin tests before the Swift test suite. For hook event mapping changes, also run `make contract`; it verifies the hook schema, fixtures, Swift parser, and plugin hook calls stay in sync.

For local development, you can manually copy your modified plugin to override the installed version:

```bash
# Override the installed plugin with your local changes
cp plugins/opencode/plugin.js ~/.config/opencode/plugins/cctop.js

# Start an opencode session — a session file should appear
ls ~/.cctop/sessions/

# Check the session file includes source: "opencode"
cat ~/.cctop/sessions/*.json | jq '.source'
```

Note: The app only installs the plugin when the user explicitly clicks "Install Plugin" — it will not overwrite your local changes automatically. However, if you click "Install Plugin" again from the UI, it will overwrite with the bundled version.

## Jump-to-Session Behavior

- **VS Code / Cursor**: Uses `NSWorkspace.open` with the editor's bundle ID to focus the project window. Does not shell out to `code`/`cursor` CLI (avoids PATH issues after Sparkle updates). If a `.code-workspace` file is detected in the project directory, it's passed instead of the folder path.
- **Workspace limitation**: cctop detects workspace files by scanning the project directory at session start. If the project folder contains a `.code-workspace` file but you opened the folder directly (not via the workspace file), cctop may incorrectly open the workspace instead of focusing the folder window. VS Code does not expose which mode was used via environment variables or APIs.
- **iTerm2**: Uses AppleScript to match the session's `ITERM_SESSION_ID` GUID against iTerm2's `unique id` property. Raises the correct window (`set index of w to 1`), selects the tab, and focuses the pane. Falls back to generic `app.activate()` if the session ID is missing or stale. Requires macOS Automation permission (prompted on first use via `NSAppleEventsUsageDescription`).
- **Other terminals**: Falls back to `NSRunningApplication.activate()` (activates the app but cannot target a specific window).

## Session Status Logic

6-status model with forward-compatible decoding. Unknown persisted statuses decode to `.needsAttention` when they contain `waiting`, otherwise `.working`. Transitions are centralized in `HookEvent.swift`. All supported clients go through `cctop-hook`; each plugin or hook shim translates its events into hook events (see tables below).

### Claude Code Hook Events

| Hook Event | Status |
|------------|--------|
| SessionStart (startup\|resume\|clear\|compact) | idle (also stores PID for liveness detection) |
| UserPromptSubmit | working |
| PreToolUse | working (sets last_tool/last_tool_detail) |
| PostToolUse | working |
| PostToolUseFailure | working (stores error in notification_message) |
| Stop | waiting_input |
| Notification (idle_prompt) | waiting_input |
| Notification (elicitation_dialog) | waiting_input |
| Notification (permission_prompt) | no status change; PermissionRequest already sets waiting_permission |
| PermissionRequest | waiting_permission |
| SubagentStart | (no status change — adds to active_subagents) |
| SubagentStop | (no status change — removes from active_subagents) |
| PreCompact | compacting |
| SessionEnd | stamps ended_at; desktop sessions also stamp disconnected_at for later lifecycle handling |

### opencode Plugin Event Mapping

The opencode plugin (`plugin.js`) translates opencode events to cctop-hook calls:

| opencode Event | Hook Event Called |
|------------|--------|
| plugin load | SessionStart |
| session.created | SessionStart |
| chat.message | UserPromptSubmit |
| tool.execute.before | PreToolUse |
| tool.execute.after | PostToolUse |
| session.idle | Stop |
| session.error | SessionError |
| session.status (retry) | SessionError |
| permission.ask | PermissionRequest |
| question.asked | PermissionRequest |
| question.replied | PostToolUse |
| question.rejected | PostToolUse |
| experimental.session.compacting | PreCompact |
| session.compacted | PostCompact |
| session.updated | (stores session_name locally, passed in subsequent calls) |
| session.deleted / permission.replied | (skipped — handled by liveness check / next event) |

### pi Extension Event Mapping

The pi extension (`cctop.ts`) translates pi events to cctop-hook calls. Non-interactive sessions (`ctx.hasUI === false`) are skipped entirely.

| pi Event | Hook Event Called |
|------------|--------|
| session_start | SessionStart (also checks `ctx.hasUI` to gate all tracking) |
| input | UserPromptSubmit |
| tool_execution_start | PreToolUse |
| tool_execution_end | PostToolUse (or PostToolUseFailure if `isError`) |
| agent_end | Stop |
| session_before_compact | PreCompact |
| session_compact | PostCompact |
| session_switch | SessionStart (updates session_name) |
| session_shutdown | SessionEnd |

### Session File Format

Non-Codex session files are keyed by PID (`{pid}.json`). Codex files are keyed by session ID (`codex-<session_id>.json`) because multiple conversations can share one host PID. Each file stores `pid_start_time` (from `sysctl`) to detect PID reuse where PID identity applies. Desktop-hosted sessions use desktop lifecycle rules, app liveness/recency, and archive visibility checks. Each session includes `"source": "<harness>"` (`"cc"`, `"opencode"`, `"pi"`, `"codex"`). Legacy sessions without the field are treated as Claude Code.

The `active_subagents` field tracks currently running subagents (Agent tool). It's `nil` for sessions that haven't reported subagent events (old plugin), `[]` when no subagents are active, or an array of `{agent_id, agent_type, started_at}` objects. The menubar app shows an agent-count label (e.g. "2 agents") when the count is > 0.

## Notch Status View

On MacBook laptops with a camera notch, the menubar icon is often hidden behind the notch. The notch status view solves this by displaying a small black pill next to the camera notch showing a grid icon + proportional status bar. Clicking the pill toggles the main panel (same as clicking the menubar icon). The panel positions itself under whichever anchor is visible (pill or menubar icon) and clamps to screen bounds.

### Auto-Detection

- **Notch Mac (built-in display):** Shows clickable NotchStatusPanel next to the notch when the menubar icon is occluded
- **Non-notch / external display:** Hides notch panel; menubar icon (44px) is always visible
- Detection uses `NSScreen.builtin?.hasPhysicalNotch` (checks `safeAreaInsets.top > 0`)
- Display changes (clamshell mode, external monitor connect/disconnect) handled via `NSApplication.didChangeScreenParametersNotification`

### Key Files

- `menubar/CctopMenubar/Extensions/NSScreen+Notch.swift` — Notch detection (`hasPhysicalNotch`, `notchSize`, `isBuiltinDisplay`)
- `menubar/CctopMenubar/Views/NotchStatusPanel.swift` — Borderless, non-activating NSPanel (clickable, toggles main panel)
- `menubar/CctopMenubar/Views/NotchStatusView.swift` — SwiftUI pill with grid icon + proportional status bar
- `menubar/CctopMenubar/Services/NotchStatusController.swift` — Panel lifecycle (`showOnScreen`, `update`, `tearDown`)
- `menubar/CctopMenubar/Views/MenubarIconRenderer.swift` — Renders 44px menubar icon (16px icon + 22px status bar)

### Keyboard Shortcuts (Panel)

| Shortcut | Context | Action |
|----------|---------|--------|
| Escape | Normal mode | Reset selection |
| Escape | Navigate mode | Cancel navigate, restore focus |
| Up/Down arrows | Panel open | Navigate sessions |
| Return | Session selected | Jump to session terminal |
| Tab | Panel open | Toggle Active/Recent tab |
| Left/Right arrows | Panel open | Switch to Active/Recent tab |
| 1-9 | Navigate mode | Jump to numbered session |

## Hook Delivery Debugging

All tools go through `cctop-hook`. When sessions stop updating,
use per-session logs in `~/.cctop/logs/` to identify which component failed.

### The Chain

```
Claude Code fires hook -> run-hook.sh (SHIM) -> cctop-hook (HOOK) -> session file -> menubar app
opencode fires event  -> plugin.js (JS)      -> cctop-hook (HOOK) -> session file -> menubar app
pi fires event        -> cctop.ts (TS)       -> cctop-hook (HOOK) -> session file -> menubar app
```

### Log Files

- `~/.cctop/logs/{session_id}.log` — Per-session log. Claude Code records SHIM + HOOK entries; direct plugins record HOOK entries once `cctop-hook` runs.
- `~/.cctop/logs/_errors.log` — Pre-parse errors (before session ID is known)

Some hook-side stale cleanup removes per-session logs. SessionManager archive/GC paths remove session JSON only.

### Log Format

Each line:

```
{ISO 8601 timestamp} {SHIM|HOOK} {event} {project}:{session_prefix} {details}
```

Examples:
```
2026-02-09T15:12:25Z     SHIM SessionStart cctop:3328c1b0 dispatching
2026-02-09T15:12:25.610Z HOOK SessionStart cctop:3328c1b0 idle -> idle
2026-02-09T15:12:26.100Z HOOK PreToolUse   cctop:517ca7b2 working -> working
```

### Diagnosing Failures

| Symptom in session log | Cause | Fix |
|------------------------|-------|-----|
| No log file for a Claude Code session | Claude Code not firing hooks | Check `claude plugin list`, restart session |
| SHIM entries but no HOOK entries | cctop-hook binary not starting | Ensure cctop.app is in /Applications/, check paths |
| HOOK entries but session file stale | File write failure | Check disk space, permissions on ~/.cctop/sessions/ |
| HOOK entries present and session file fresh, but not visible | Visibility/archive/hidden/lifecycle filter or file watcher issue | Inspect session JSON fields first; restart the menubar app only after ruling out filters |
| Entries stop but session is still running | Client stopped firing hooks | Check client process/lifecycle state and whether PID or desktop app liveness still applies |

### Diagnosing Wrong Session Identity

When a session shows the wrong source, badge, grouping, or client-specific cleanup behavior, inspect the session file before editing UI logic:

```bash
cat ~/.cctop/sessions/<session-file>.json \
  | jq '{source, created_by_hook_version, last_written_by_hook_version}'
```

- `created_by_hook_version == null` or missing means the file was probably created by a pre-metadata/outdated hook. Check whether `~/.cctop/bin/cctop-hook` points at the current app-bundled hook and whether the app launch repair path ran.
- `created_by_hook_version` missing but `last_written_by_hook_version` current means a legacy file was later updated by a current hook; do not infer the original writer.
- Both fields current means the hook writer is probably not stale; inspect resolved harness/source, client event delivery/logs, PID/app liveness, and visibility/lifecycle classification as relevant to the symptom.
- If `source` is `opencode` or `pi` but `terminal.bundle_id` is `com.openai.codex` or `com.anthropic.claudefordesktop`, keep the opencode/pi identity and debug plugin process lifecycle. Those explicit non-desktop harnesses can inherit GUI bundle IDs from the launching environment.

### Quick Commands

```bash
# Watch a specific session's events in real time
tail -f ~/.cctop/logs/<session-id>.log

# Show only state-changing transitions (skip working -> working noise)
grep 'HOOK' ~/.cctop/logs/<session-id>.log | grep -v 'working -> working'

# Show all logs across sessions
cat ~/.cctop/logs/*.log | sort | tail -40

# Show only SHIM entries (verify hooks are being dispatched)
grep 'SHIM' ~/.cctop/logs/<session-id>.log

# Check pre-parse errors
cat ~/.cctop/logs/_errors.log
```

## Plugin Debugging (opencode / pi)

Both plugins call `cctop-hook` via `execFileSync`, so per-session logs in `~/.cctop/logs/` work the same as Claude Code. If `cctop-hook` isn't found, calls silently fail. Pi additionally skips non-interactive sessions (`ctx.hasUI === false`) — no session file or log will be created.

| Symptom | Cause | Fix |
|---------|-------|-----|
| No session file appears | Plugin not installed, cctop-hook not found, or (pi only) non-interactive session | Verify plugin: `ls ~/.config/opencode/plugins/cctop.js` or `ls ~/.pi/agent/extensions/cctop.ts`. Verify binary: `ls /Applications/cctop.app/Contents/MacOS/cctop-hook` or `~/.cctop/bin/cctop-hook` |
| No HOOK entries in logs | Plugin calling hook but binary failing | Check `~/.cctop/logs/_errors.log` for parse errors |
| Session file appears but status doesn't update | Plugin event handler error or stale plugin | Check tool console for JS/TS errors; reinstall via Settings > Monitored Tools |

```bash
# Verify source field per session
cat ~/.cctop/sessions/*.json | jq '{project: .project_name, status: .status, source: .source}'
```

## General Debugging Tips

```bash
# Check what Claude Code sends to hooks
grep "hook" ~/.claude/debug/<session-id>.txt | head -20

# List running claude processes and their directories
ps aux | grep -E 'claude|Claude' | grep -v grep

# Check specific process working directory
lsof -p <PID> | grep cwd

# View session file contents
cat ~/.cctop/sessions/*.json | jq '.project_name + " | " + .status'
```

## Release Pipeline

The release is triggered by pushing a version tag (`v*`). The GitHub Actions workflow (`.github/workflows/release.yml`) runs 5 jobs:

1. **Build macOS** (matrix: arm64 + x86_64) — `xcodebuild` archive + `scripts/bundle-macos.sh`
2. **Sign & Notarize** — `scripts/sign-and-notarize.sh` (per-arch)
3. **Create Release** — uploads both ZIPs to GitHub Releases
4. **Update Sparkle Appcast** — `scripts/generate-appcast.sh` updates `appcast.xml` on master
5. **Update Homebrew Tap** — updates the cask formula

### Code Signing Strategy

Sparkle framework components must be signed **without** the app's entitlements. Only the main executable and the `.app` bundle itself get `--entitlements`. Everything else (XPC services, helper apps, framework dylibs, standalone binaries) gets just identity + hardened runtime + timestamp. This is critical for notarization — Apple rejects bundles where XPC services have inappropriate entitlements like `com.apple.security.automation.apple-events`.

The signing order is inside-out: dylibs first, then inner executables, then nested bundles (depth-first), then main executable, then the app bundle.

**Key pitfall**: Sparkle's `Autoupdate` binary lives at `Sparkle.framework/Versions/B/Autoupdate` (no `MacOS/` in path). The discovery function must search `*/Frameworks/*` in addition to `*/MacOS/*` to find it.

Use `--dry-run` to verify signing order without actually signing:
```bash
./scripts/sign-and-notarize.sh --dry-run dist/cctop.app
```

### Multi-Arch Appcast

`generate_appcast` (Sparkle's tool) cannot handle multiple ZIPs with the same bundle version. The script works around this by:
1. Normalizing input ZIP order so the arm64 ZIP is primary
2. Generating the appcast with only the arm64 ZIP
3. Marking the arm64 item with `sparkle:hardwareRequirements`
4. Signing the x86_64 ZIP separately with `sign_update`
5. Duplicating the generated item for x86_64 with its own `sparkle:cpu` enclosure
6. Validating that the latest appcast version has separate arm64 and x86_64 items

Do not put arm64 and x86_64 enclosures in the same `<item>`. Sparkle treats hardware requirements at the item level and exposes one update file URL per item, so a shared item can make Intel clients download the arm64 archive.

### Homebrew Caskroom PATH

Homebrew's sparkle cask only symlinks the `sparkle` binary to `/opt/homebrew/bin/`. The `generate_appcast` and `sign_update` tools live in `/opt/homebrew/Caskroom/sparkle/*/bin/` and the script auto-discovers this path.

### Debugging Release Failures

```bash
# Re-run signing locally with dry-run to check order
./scripts/sign-and-notarize.sh --dry-run dist/cctop.app

# Sign without notarizing (faster iteration)
./scripts/sign-and-notarize.sh --sign-only dist/cctop.app

# Test appcast generation locally
SPARKLE_PRIVATE_KEY_FILE=~/.sparkle_ed25519 ./scripts/generate-appcast.sh --version 0.7.0 arm64.zip x86_64.zip
```

If notarization fails, the script automatically fetches the notarization log via `xcrun notarytool log`. Common causes:
- Sparkle components signed with app entitlements (see signing strategy above)
- Unsigned binaries in non-standard paths (like `Autoupdate`)
- Missing hardened runtime flag

## Menubar Screenshot

The menubar screenshots (`docs/menubar-light.png` and `docs/menubar-dark.png`) are generated from a snapshot test that renders `PopupView` with mock data:

```bash
# Regenerate the menubar screenshots (light + dark)
xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
  -only-testing:CctopMenubarTests/SnapshotTests/testGenerateMenubarScreenshot \
  -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
cp /tmp/menubar-light.png /tmp/menubar-dark.png docs/
```

The showcase sessions are defined in `Session+Mock.swift` (`qaShowcase`). Edit that array to change what appears in the screenshots.

## Design Context

See [DESIGN.md](DESIGN.md) for the visual design system — color palettes per theme, typography ladder, component specs, layout principles, and the do's/don'ts that govern visual decisions. When making UI changes, treat DESIGN.md as the source of truth and update it if the implementation needs to evolve.
