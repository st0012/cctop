#!/bin/sh
# Verify that hooks.json registers handlers for all spec events.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
HOOKS_JSON="$ROOT_DIR/plugins/cctop/hooks/hooks.json"

# Events that Claude Code fires (subset of the full spec).
# PostCompact and SessionError are opencode-only — CC doesn't fire them.
CC_EVENTS="SessionStart SessionEnd UserPromptSubmit Stop PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification SubagentStart SubagentStop PreCompact"

missing=0
for event in $CC_EVENTS; do
    if ! grep -q "\"$event\"" "$HOOKS_JSON"; then
        echo "MISSING: $event not found in $HOOKS_JSON"
        missing=$((missing + 1))
    fi
done

if [ "$missing" -gt 0 ]; then
    echo "ERROR: $missing events missing from hooks.json"
    exit 1
fi

echo "All spec events covered in hooks.json."
