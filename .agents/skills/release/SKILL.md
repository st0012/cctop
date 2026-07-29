---
name: release
description: Use when cutting or preparing a cctop release - "cut a release", "release vX.Y.Z", "prepare a release", "bump the version and tag", "ship a new version". Drives proportionate release checks, version bump, CI, tag push, release monitoring, and verification. An explicit release request authorizes the complete release unless the developer asks to stop before publication.
---

# Cutting a cctop Release

Releases are triggered by pushing a `v*` tag. `.github/workflows/release.yml` then runs: build (arm64 + x86_64, zip + DMG each) -> sign and notarize -> create GitHub Release -> update Sparkle appcast on master -> update Homebrew cask.

## Authorization and checks

- Treat an explicit request to **release**, **cut**, or **ship** a version as authorization for the complete release: assess scope, run proportionate checks, bump and land the version, push the tag, supervise publication, and verify downstream metadata. Do not insert another routine approval gate when all expected checks pass.
- A request to **prepare**, **assess**, or **check whether ready** is not publication authorization. Stop before the tag and ask for the final go.
- Before proposing or adding any release check, state its reason in plain language: name the concrete failure or release risk it covers and why the shipped changes make that risk relevant. Do not propose a check merely because an older or larger release used it.
- Scale checks to the release. Previously approved PR tests are feature evidence; release checks should cover integration, versioning, packaging, and risks introduced by the exact release range. Patch releases should not inherit major-release manual tests without a specific reason.
- Once an authorized release's checks pass, continue automatically. Stop only when a check fails unexpectedly, the release range/version is ambiguous, unrelated changes appear, publication requires a genuinely new product decision, or the developer asks to pause.
- Never merge feature PRs; the developer merges them. The approved release bump may land by the agreed repository path.

## 1. Establish the release contract

1. Sync and review what's shipping: `git pull` then `git log $(git describe --tags --abbrev=0)..origin/master --oneline`.
2. Propose or confirm the semver bump and a short changelog summary.
3. State how the bump commit will land. Direct push to master is allowed for this repo; most releases use this path. Use a PR if the developer prefers.
4. List the release checks and give one concise reason for each. Remove checks whose reason is only habit or duplication of already-approved feature evidence.
5. If the developer explicitly requested the release and the version/scope are clear, continue. If they only requested preparation/readiness assessment, stop for approval.

## 2. Bump the version

- Always use `scripts/bump-version.sh <version>`; never edit version numbers by hand. The script updates the Xcode project, `Config.hookVersion`, plugin manifests, packaging, and the site fallback badge together.
- Run `make all` (lint + contract + build + test) before committing.
- Commit `Bump version to <version>` and land it per step 1.
- If a PR was used: monitor CI to green, then stop and let the developer merge.

## 3. Confirm green

- Wait for master CI on the bump commit: `gh run list --branch master --limit 5`, then `gh run watch <id>`.
- For an explicitly authorized release, continue to the exact tag as soon as expected checks and master CI pass.
- For preparation/readiness-only work, report the exact candidate and stop for tag authorization. The tag push publishes the release, appcast update, and cask bump.

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
