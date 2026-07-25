#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FILES=(
    packaging/homebrew-cask.rb
    plugins/cctop/.claude-plugin/plugin.json
    .claude-plugin/marketplace.json
    menubar/CctopMenubar.xcodeproj/project.pbxproj
    menubar/CctopMenubar/Models/Config.swift
    plugins/opencode/package.json
    plugins/streamdeck/package.json
    plugins/streamdeck/com.st0012.cctop.sdPlugin/manifest.json
    site/index.html
)

mkdir -p "$TEST_ROOT/scripts"
cp "$REPO_ROOT/scripts/bump-version.sh" "$TEST_ROOT/scripts/bump-version.sh"
for file in "${FILES[@]}"; do
    mkdir -p "$TEST_ROOT/$(dirname "$file")"
    cp "$REPO_ROOT/$file" "$TEST_ROOT/$file"
done

"$TEST_ROOT/scripts/bump-version.sh" 9.8.7 >/dev/null
MANIFEST="$TEST_ROOT/plugins/streamdeck/com.st0012.cctop.sdPlugin/manifest.json"
PACKAGE="$TEST_ROOT/plugins/streamdeck/package.json"

grep -q '"Version": "9.8.7.0"' "$MANIFEST"
grep -A1 '"Nodejs"' "$MANIFEST" | grep -q '"Version": "24"'
grep -q '"version": "9.8.7"' "$PACKAGE"

echo "Stream Deck version bump test passed."
