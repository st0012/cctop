# Contributing to cctop

Thanks for your interest in contributing to cctop! This project has two main components:

- **Rust** - TUI (`cctop`) and hook binary (`cctop-hook`)
- **Swift/SwiftUI** - macOS menubar app (`CctopMenubar`)

## Getting Started

### Prerequisites

- [Rust](https://rustup.rs/) (stable)
- Xcode 16+ (for the menubar app)
- [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`)

### Building

```bash
# Rust binaries
cargo build

# Swift menubar app
xcodebuild build \
  -project menubar/CctopMenubar.xcodeproj \
  -scheme CctopMenubar \
  -configuration Debug \
  -derivedDataPath menubar/build/ \
  CODE_SIGN_IDENTITY="-"
```

### Running Tests

```bash
# Rust tests
cargo test

# Swift tests
xcodebuild test \
  -project menubar/CctopMenubar.xcodeproj \
  -scheme CctopMenubar \
  -configuration Debug \
  -derivedDataPath menubar/build/

# Lint checks
cargo fmt --check
cargo clippy -- -D warnings
swiftlint lint --strict
```

## Making Changes

1. Fork the repository and create a branch from `master`.
2. Make your changes. Add tests if applicable.
3. Run the full test and lint suite (see above).
4. Open a pull request against `master`.

### Rust Changes

Source is in `src/`. The main data flow is:

```
cctop-hook (src/bin/cctop_hook.rs)  -->  session files  -->  TUI (src/tui.rs)
```

`src/session.rs` defines the shared `Session` struct used by both binaries.

### Swift Changes

Source is in `menubar/CctopMenubar/`. Use Xcode or SwiftUI Previews for visual feedback -- all views have `#Preview` blocks with mock data.

The menubar app reads the same `~/.cctop/sessions/*.json` files written by `cctop-hook`. The JSON format is the interface contract between Rust and Swift.

### Version Bumping

When releasing a new version, use the bump script to update all version references at once:

```bash
./scripts/bump-version.sh 0.3.0
```

This updates `Cargo.toml`, `packaging/homebrew-cask.rb`, and the plugin manifests.

## Reporting Issues

Open an issue on [GitHub](https://github.com/st0012/cctop/issues). Include:

- What you expected vs. what happened
- Steps to reproduce
- Output of `cctop --list` if relevant
- Your OS version and architecture

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
