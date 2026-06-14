---
name: release
description: Use when cutting a cctop release - "cut a release", "release vX.Y.Z", "bump the version and tag", "ship a new version". Drives version bump, CI, tag push, release pipeline monitoring, and verification, with hard approval gates before anything becomes public.
---

# Cutting a cctop Release

Releases are triggered by pushing a `v*` tag. `.github/workflows/release.yml` then runs: build (arm64 + x86_64, zip + DMG each) -> sign and notarize -> create GitHub Release -> update Sparkle appcast on master -> update Homebrew cask.

There are two hard approval gates. Do not pass either without the developer's explicit go. Never merge PRs; the developer merges.

## 1. Propose the release (GATE 1)

1. Sync and review what's shipping: `git pull` then `git log $(git describe --tags --abbrev=0)..origin/master --oneline`.
2. Propose a semver bump and a short changelog summary.
3. State how the bump commit will land. Direct push to master is allowed for this repo; most releases use this path. Use a PR if the developer prefers.
4. Stop and wait for explicit approval of the version and summary.

## 2. Bump the version

- Always use `scripts/bump-version.sh <version>`; never edit version numbers by hand. The script updates the Xcode project, `Config.hookVersion`, plugin manifests, packaging, and the site fallback badge together.
- Run `make all` (lint + contract + build + test) before committing.
- Commit `Bump version to <version>` and land it per step 1.
- If a PR was used: monitor CI to green, then stop and let the developer merge.

## 3. Confirm green and get the final go (GATE 2)

- Wait for master CI on the bump commit: `gh run list --branch master --limit 5`, then `gh run watch <id>`.
- Confirm with the developer before pushing the tag. The tag push is the irreversible step: it publishes the release, appcast update, and cask bump.

## 4. Tag and monitor the pipeline

```bash
git tag v<version> && git push origin v<version>
```

- Monitor the Release workflow to completion (`gh run watch`, or poll `gh run list --workflow release.yml` with retry/backoff on transient `gh` failures).
- Do not name shell variables `status`; it is readonly in zsh and has silently broken CI watchers before.
- If any job fails, stop immediately and report the exact failure with logs. Signing/notarization pitfalls are documented in `AGENTS.md` under Release Pipeline. The `--dry-run` and `--sign-only` flags on `scripts/sign-and-notarize.sh` help local debugging.

## 5. Verify

- `gh release view v<version>` lists all four assets: `cctop-macOS-{arm64,x86_64}.{zip,dmg}`.
- `appcast.xml` on master has separate arm64 and x86_64 `<item>` entries for the new version. CI commits this; pull and check.
- The Homebrew cask job succeeded.
- Report the release URL and what was verified.
