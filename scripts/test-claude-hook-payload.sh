#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$SCRIPT_DIR/../plugins/cctop/hooks/run-hook.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Intercept the first dispatch branch before the shim can reach an installed hook.
mkdir -p "$TMP_DIR/.cctop/bin"
cat > "$TMP_DIR/.cctop/bin/cctop-hook" <<'HOOK'
#!/bin/sh
cat > "$HOME/forwarded.json"
printf '%s\n' "$@" > "$HOME/arguments"
HOOK
chmod +x "$TMP_DIR/.cctop/bin/cctop-hook"

check_payload() {
    local event="$1"
    local payload="$2"
    printf '%s\n' "$payload" > "$TMP_DIR/expected.json"
    jq -e . "$TMP_DIR/expected.json" > /dev/null
    HOME="$TMP_DIR" /bin/sh "$SHIM" "$event" < "$TMP_DIR/expected.json"
    cmp "$TMP_DIR/expected.json" "$TMP_DIR/forwarded.json"
    jq -e . "$TMP_DIR/forwarded.json" > /dev/null
    printf '%s\n' "$event" --harness cc > "$TMP_DIR/expected-arguments"
    cmp "$TMP_DIR/expected-arguments" "$TMP_DIR/arguments"
}

check_payload UserPromptSubmit '{"session_id":"prompt-test","cwd":"/tmp/project","prompt":"first line\nsecond line"}'
check_payload PostToolUse '{"session_id":"tool-test","cwd":"/tmp/project","tool_response":"first line\nsecond line\tC:\\temp"}'
check_payload Stop '{"session_id":"ordinary-test","cwd":"/tmp/project"}'

echo "Claude hook payload tests passed."
