#!/bin/bash
set -euo pipefail

TAG_NAME="${1:-${GITHUB_REF_NAME:-}}"

if [ -z "$TAG_NAME" ]; then
    echo "Error: release tag is required (pass vX.Y.Z or set GITHUB_REF_NAME)"
    exit 1
fi

if [[ ! "$TAG_NAME" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "Error: release tag must look like vX.Y.Z, got: $TAG_NAME"
    exit 1
fi

TAG_VERSION="${BASH_REMATCH[1]}"
TAG_BUILD_NUMBER=$(echo "$TAG_VERSION" | awk -F. '{print $1*10000 + $2*100 + $3}')
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_SWIFT="$REPO_ROOT/menubar/CctopMenubar/Models/Config.swift"
PBXPROJ="$REPO_ROOT/menubar/CctopMenubar.xcodeproj/project.pbxproj"

HOOK_VERSION=$(sed -nE 's/^[[:space:]]*static let hookVersion = "([^"]+)".*/\1/p' "$CONFIG_SWIFT")
if [ "$HOOK_VERSION" != "$TAG_VERSION" ]; then
    echo "Error: $TAG_NAME does not match Config.hookVersion ($HOOK_VERSION)"
    exit 1
fi

MARKETING_VERSION_COUNT=0
while IFS= read -r version; do
    MARKETING_VERSION_COUNT=$((MARKETING_VERSION_COUNT + 1))
    if [ "$version" != "$TAG_VERSION" ]; then
        echo "Error: $TAG_NAME does not match MARKETING_VERSION ($version)"
        exit 1
    fi
done < <(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);.*/\1/p' "$PBXPROJ")

if [ "$MARKETING_VERSION_COUNT" -eq 0 ]; then
    echo "Error: no MARKETING_VERSION values found in $PBXPROJ"
    exit 1
fi

CURRENT_PROJECT_VERSION_COUNT=0
while IFS= read -r version; do
    CURRENT_PROJECT_VERSION_COUNT=$((CURRENT_PROJECT_VERSION_COUNT + 1))
    if [ "$version" != "$TAG_BUILD_NUMBER" ]; then
        echo "Error: $TAG_NAME build number ($TAG_BUILD_NUMBER) does not match CURRENT_PROJECT_VERSION ($version)"
        exit 1
    fi
done < <(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);.*/\1/p' "$PBXPROJ")

if [ "$CURRENT_PROJECT_VERSION_COUNT" -eq 0 ]; then
    echo "Error: no CURRENT_PROJECT_VERSION values found in $PBXPROJ"
    exit 1
fi

echo "Release version guard passed: $TAG_NAME matches Config.hookVersion, $MARKETING_VERSION_COUNT MARKETING_VERSION values, and $CURRENT_PROJECT_VERSION_COUNT CURRENT_PROJECT_VERSION values"
