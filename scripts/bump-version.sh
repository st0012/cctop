#!/bin/bash
set -euo pipefail

# bump-version.sh - Update version across all project files
#
# Usage:
#   ./scripts/bump-version.sh 0.3.0

if [ $# -ne 1 ]; then
    echo "Usage: $0 <new-version>"
    echo "Example: $0 0.3.0"
    exit 1
fi

NEW_VERSION="$1"

# Validate version format (semver without prefix)
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: version must be semver (e.g. 0.3.0), got: $NEW_VERSION"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Bumping version to $NEW_VERSION..."

# 1. Cargo.toml
sed -i '' "s/^version = \".*\"/version = \"$NEW_VERSION\"/" "$REPO_ROOT/Cargo.toml"
echo "  Updated Cargo.toml"

# 2. packaging/homebrew-cask.rb
sed -i '' "s/^  version \".*\"/  version \"$NEW_VERSION\"/" "$REPO_ROOT/packaging/homebrew-cask.rb"
echo "  Updated packaging/homebrew-cask.rb"

# 3. plugins/cctop/.claude-plugin/plugin.json
sed -i '' "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/" "$REPO_ROOT/plugins/cctop/.claude-plugin/plugin.json"
echo "  Updated plugins/cctop/.claude-plugin/plugin.json"

# 4. .claude-plugin/marketplace.json (has two version fields)
sed -i '' "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/g" "$REPO_ROOT/.claude-plugin/marketplace.json"
echo "  Updated .claude-plugin/marketplace.json"

# Regenerate Cargo.lock
(cd "$REPO_ROOT" && cargo check --quiet 2>/dev/null) || true
echo "  Regenerated Cargo.lock"

echo ""
echo "Done! Version bumped to $NEW_VERSION in all files."
echo "Verify with: grep -r '\"$NEW_VERSION\"' Cargo.toml packaging/ plugins/ .claude-plugin/"
