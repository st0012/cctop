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

# 1. packaging/homebrew-cask.rb
sed -i '' "s/^  version \".*\"/  version \"$NEW_VERSION\"/" "$REPO_ROOT/packaging/homebrew-cask.rb"
echo "  Updated packaging/homebrew-cask.rb"

# 2. plugins/cctop/.claude-plugin/plugin.json
sed -i '' "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/" "$REPO_ROOT/plugins/cctop/.claude-plugin/plugin.json"
echo "  Updated plugins/cctop/.claude-plugin/plugin.json"

# 3. .claude-plugin/marketplace.json (has two version fields)
sed -i '' "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/g" "$REPO_ROOT/.claude-plugin/marketplace.json"
echo "  Updated .claude-plugin/marketplace.json"

# 4. Xcode project - MARKETING_VERSION (all build configs)
PBXPROJ="$REPO_ROOT/menubar/CctopMenubar.xcodeproj/project.pbxproj"
sed -i '' "s/MARKETING_VERSION = .*/MARKETING_VERSION = $NEW_VERSION;/" "$PBXPROJ"
echo "  Updated pbxproj MARKETING_VERSION"

# 5. Xcode project - CURRENT_PROJECT_VERSION (derived: major*10000 + minor*100 + patch)
BUILD_NUM=$(echo "$NEW_VERSION" | awk -F. '{print $1*10000 + $2*100 + $3}')
sed -i '' "s/CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $BUILD_NUM;/" "$PBXPROJ"
echo "  Updated pbxproj CURRENT_PROJECT_VERSION to $BUILD_NUM"

# 6. Hook writer version string
CONFIG_SWIFT="$REPO_ROOT/menubar/CctopMenubar/Models/Config.swift"
sed -i '' "s/static let hookVersion = \".*\"/static let hookVersion = \"$NEW_VERSION\"/" "$CONFIG_SWIFT"
if ! grep -q "static let hookVersion = \"$NEW_VERSION\"" "$CONFIG_SWIFT"; then
    echo "Error: failed to update Config.hookVersion"
    exit 1
fi
echo "  Updated Config.hookVersion"

# 7. plugins/opencode/package.json
sed -i '' "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/" "$REPO_ROOT/plugins/opencode/package.json"
echo "  Updated plugins/opencode/package.json"

# 8. site/index.html — static fallback for the version badge.
# A small fetch() to api.github.com overrides this at runtime when online,
# but the static value is what users see if the request fails (rate limit, offline).
sed -i '' -E "/data-version/s|v[0-9]+\\.[0-9]+\\.[0-9]+|v$NEW_VERSION|" "$REPO_ROOT/site/index.html"
if ! grep -q "data-version>v$NEW_VERSION<" "$REPO_ROOT/site/index.html"; then
    echo "Error: failed to update site/index.html version fallback"
    exit 1
fi
echo "  Updated site/index.html"

# 9. Launch-video source fallbacks.
for launch_source in \
    "$REPO_ROOT/video/projects/launch/body.html" \
    "$REPO_ROOT/video/projects/launch/storyboard.html"
do
    sed -i '' -E "s|v[0-9]+\\.[0-9]+\\.[0-9]+|v$NEW_VERSION|g" "$launch_source"
    if ! grep -q "class=\"version\">v$NEW_VERSION<" "$launch_source"; then
        echo "Error: failed to update $launch_source version fallback"
        exit 1
    fi
done
echo "  Updated launch-video source fallbacks"

# 10. Stream Deck package metadata. Its manifest requires four numeric
# components; match only that shape so Nodejs.Version remains untouched.
SD_PACKAGE="$REPO_ROOT/plugins/streamdeck/package.json"
sed -i '' "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/" "$SD_PACKAGE"
SD_MANIFEST="$REPO_ROOT/plugins/streamdeck/com.st0012.cctop.sdPlugin/manifest.json"
perl -0pi -e 's/"Version":\s*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"/"Version": "'"$NEW_VERSION"'.0"/' "$SD_MANIFEST"
if ! grep -q "\"Version\": \"$NEW_VERSION.0\"" "$SD_MANIFEST" \
    || ! grep -A1 '"Nodejs"' "$SD_MANIFEST" | grep -q '"Version": "24"'; then
    echo "Error: failed to update Stream Deck manifest safely"
    exit 1
fi
echo "  Updated Stream Deck package and manifest"

echo ""
echo "Done! Version bumped to $NEW_VERSION in all files."
echo "Verify with: grep -r '\"$NEW_VERSION\"' packaging/ plugins/ .claude-plugin/"
echo "Xcode:  grep 'MARKETING_VERSION\|CURRENT_PROJECT_VERSION' $PBXPROJ"
