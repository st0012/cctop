# Contributing to cctop

Thanks for your interest in contributing to cctop! The project has three main components:

- **CctopMenubar** - macOS menubar app (SwiftUI)
- **cctop-hook** - CLI hook handler for Claude Code (Swift, Xcode target)
- **opencode plugin** - JS plugin for opencode (`plugins/opencode/plugin.js`)

The two Swift targets share model code in `Models/`. The opencode plugin is a standalone JS file with zero dependencies.

## Getting Started

### Prerequisites

- Xcode 16+ (for Swift 6.1 tools)
- [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`)

### Building

```bash
# Menubar app
xcodebuild build \
  -project menubar/CctopMenubar.xcodeproj \
  -scheme CctopMenubar \
  -configuration Debug \
  -derivedDataPath menubar/build/ \
  CODE_SIGN_IDENTITY="-"

# cctop-hook CLI
xcodebuild build \
  -project menubar/CctopMenubar.xcodeproj \
  -scheme cctop-hook \
  -configuration Debug \
  -derivedDataPath menubar/build/ \
  CODE_SIGN_IDENTITY="-"
```

### Running Tests

```bash
# Swift tests
xcodebuild test \
  -project menubar/CctopMenubar.xcodeproj \
  -scheme CctopMenubar \
  -configuration Debug \
  -derivedDataPath menubar/build/

# Lint checks
swiftlint lint --strict
```

## Making Changes

1. Fork the repository and create a branch from `master`.
2. Make your changes. Add tests if applicable.
3. Run the full test and lint suite (see above).
4. Open a pull request against `master`.

### Code Organization

**Swift** (in `menubar/CctopMenubar/`). Use Xcode or SwiftUI Previews for visual feedback -- all views have `#Preview` blocks with mock data.

- `Models/` — Shared between both Swift targets (Session, SessionStatus, HookEvent, Config)
- `Views/` — Menubar app only (SwiftUI views)
- `Services/` — Menubar app only (SessionManager, FocusTerminal)
- `Hook/` — cctop-hook CLI only (HookMain, HookHandler, HookInput, HookLogger)

**opencode plugin** (in `plugins/opencode/`). A single JS file that runs in-process in Bun.

- `plugin.js` — Event handler that writes session JSON to `~/.cctop/sessions/`
- `package.json` — Plugin manifest (name, version)
- No build step needed — edit `plugin.js` directly and copy to `~/.config/opencode/plugins/cctop.js` to test

### Testing the opencode Plugin Locally

```bash
# Copy your modified plugin into the opencode plugins directory
cp plugins/opencode/plugin.js ~/.config/opencode/plugins/cctop.js

# Restart opencode to pick up changes
# (opencode loads plugins at startup — there's no hot reload)

# Verify session files are written
ls ~/.cctop/sessions/

# Check the session JSON contents
cat ~/.cctop/sessions/*.json | python3 -m json.tool

# Watch for new session events in real time
ls -lt ~/.cctop/sessions/ | head -5
```

The plugin runs inside opencode's Bun runtime — no separate Node.js or Bun install is needed. You can check syntax without opencode by running `node -c plugins/opencode/plugin.js`.

### Version Bumping

When releasing a new version, use the bump script to update all version references at once:

```bash
./scripts/bump-version.sh 0.3.0
```

This updates `packaging/homebrew-cask.rb`, both plugin manifests (Claude Code and opencode), and the Xcode project.

## Reporting Issues

Open an issue on [GitHub](https://github.com/st0012/cctop/issues). Include:

- What you expected vs. what happened
- Steps to reproduce
- Your OS version and architecture

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
