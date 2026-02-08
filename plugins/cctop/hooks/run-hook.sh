#!/bin/sh
# run-hook.sh - Locate and run cctop-hook binary
# Shipped with the cctop Claude Code plugin.
# Checks common install locations and forwards the hook event.

EVENT="$1"

if [ -x "$HOME/.cargo/bin/cctop-hook" ]; then
    exec "$HOME/.cargo/bin/cctop-hook" "$EVENT"
elif [ -x "$HOME/.local/bin/cctop-hook" ]; then
    exec "$HOME/.local/bin/cctop-hook" "$EVENT"
elif [ -x "/opt/homebrew/bin/cctop-hook" ]; then
    exec /opt/homebrew/bin/cctop-hook "$EVENT"
elif [ -x "/usr/local/bin/cctop-hook" ]; then
    exec /usr/local/bin/cctop-hook "$EVENT"
elif command -v cctop-hook >/dev/null 2>&1; then
    exec cctop-hook "$EVENT"
fi
