#!/bin/sh
# cctop shim for Codex CLI hooks.
# Installed to ~/.codex/cctop-shim.sh by the cctop menubar app.
# Dispatches Codex hook events to cctop-hook with --harness codex.

EVENT="$1"
[ -z "$EVENT" ] && exit 0

for CANDIDATE in \
    "$HOME/.cctop/bin/cctop-hook" \
    "/Applications/cctop.app/Contents/MacOS/cctop-hook" \
    "$HOME/Applications/cctop.app/Contents/MacOS/cctop-hook"
do
    if [ -x "$CANDIDATE" ]; then
        exec "$CANDIDATE" "$EVENT" --harness codex
    fi
done

# Binary not found — leave a breadcrumb so users can diagnose silent failure.
mkdir -p "$HOME/.cctop/logs" 2>/dev/null
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$TS SHIM codex $EVENT cctop-hook not found at expected locations" \
    >> "$HOME/.cctop/logs/_errors.log" 2>/dev/null
exit 0
