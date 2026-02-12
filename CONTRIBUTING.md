# Contributing to cctop

Thanks for your interest in contributing to cctop! The project is a pure Swift macOS app with two Xcode targets:

- **CctopMenubar** - macOS menubar app (SwiftUI)
- **cctop-hook** - CLI hook handler called by Claude Code

Both targets share model code in `Models/`.

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

Source is in `menubar/CctopMenubar/`. Use Xcode or SwiftUI Previews for visual feedback -- all views have `#Preview` blocks with mock data.

- `Models/` — Shared between both targets (Session, SessionStatus, HookEvent, Config)
- `Views/` — Menubar app only (SwiftUI views)
- `Services/` — Menubar app only (SessionManager, FocusTerminal)
- `Hook/` — cctop-hook CLI only (HookMain, HookHandler, HookInput, HookLogger)

### Version Bumping

When releasing a new version, use the bump script to update all version references at once:

```bash
./scripts/bump-version.sh 0.3.0
```

This updates `packaging/homebrew-cask.rb`, the plugin manifests, and the Xcode project.

## Reporting Issues

Open an issue on [GitHub](https://github.com/st0012/cctop/issues). Include:

- What you expected vs. what happened
- Steps to reproduce
- Your OS version and architecture

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
