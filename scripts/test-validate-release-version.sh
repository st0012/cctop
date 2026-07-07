#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/validate-release-version.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

make_repo() {
    local version="$1"
    local build_number="$2"
    local repo="$TMP_DIR/repo"

    rm -rf "$repo"
    mkdir -p "$repo/scripts"
    mkdir -p "$repo/menubar/CctopMenubar/Models"
    mkdir -p "$repo/menubar/CctopMenubar.xcodeproj"

    cp "$SOURCE_SCRIPT" "$repo/scripts/validate-release-version.sh"
    chmod +x "$repo/scripts/validate-release-version.sh"

    cat > "$repo/menubar/CctopMenubar/Models/Config.swift" <<EOF
enum Config {
    static let hookVersion = "$version"
}
EOF

    cat > "$repo/menubar/CctopMenubar.xcodeproj/project.pbxproj" <<EOF
CURRENT_PROJECT_VERSION = $build_number;
MARKETING_VERSION = $version;
CURRENT_PROJECT_VERSION = $build_number;
MARKETING_VERSION = $version;
EOF
}

expect_success() {
    local tag="$1"
    "$TMP_DIR/repo/scripts/validate-release-version.sh" "$tag" >/tmp/cctop-release-guard-success.log
}

expect_failure() {
    local tag="$1"
    local expected="$2"
    local output="$TMP_DIR/failure.log"

    if "$TMP_DIR/repo/scripts/validate-release-version.sh" "$tag" >"$output" 2>&1; then
        echo "Expected validate-release-version.sh $tag to fail"
        cat "$output"
        exit 1
    fi

    if ! grep -q "$expected" "$output"; then
        echo "Expected failure output to contain: $expected"
        cat "$output"
        exit 1
    fi
}

make_repo "1.2.3" "10203"
expect_success "v1.2.3"

make_repo "1.2.3" "10203"
expect_failure "v1.2.4" "Config.hookVersion"

make_repo "1.2.3" "99999"
expect_failure "v1.2.3" "CURRENT_PROJECT_VERSION"

echo "Release version guard tests passed."
