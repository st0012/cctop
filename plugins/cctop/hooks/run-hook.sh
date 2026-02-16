#!/bin/sh
# run-hook.sh - Locate and run cctop-hook binary
# Shipped with the cctop Claude Code plugin.
# Buffers stdin, logs a SHIM entry to the per-session log, then dispatches to cctop-hook.

EVENT="$1"
umask 077
LOGS_DIR="$HOME/.cctop/logs"
mkdir -p "$LOGS_DIR"

# Buffer stdin so we can log before dispatching
INPUT=$(cat)

# Extract session ID and label for logging
CWD=$(echo "$INPUT" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p' | head -1)
SID=$(echo "$INPUT" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -1)
SID=$(echo "$SID" | tr -cd 'a-zA-Z0-9_-')
PROJECT=$(basename "$CWD")
LABEL="${PROJECT:-unknown}:$(echo "$SID" | cut -c1-8)"
LOG="$LOGS_DIR/${SID}.log"
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

echo "$TS SHIM $EVENT $LABEL dispatching" >> "$LOG" 2>/dev/null

if [ -x "$HOME/.cctop/bin/cctop-hook" ]; then
    echo "$INPUT" | "$HOME/.cctop/bin/cctop-hook" "$EVENT"
elif [ -x "/Applications/cctop.app/Contents/MacOS/cctop-hook" ]; then
    echo "$INPUT" | /Applications/cctop.app/Contents/MacOS/cctop-hook "$EVENT"
elif [ -x "$HOME/Applications/cctop.app/Contents/MacOS/cctop-hook" ]; then
    echo "$INPUT" | "$HOME/Applications/cctop.app/Contents/MacOS/cctop-hook" "$EVENT"
else
    echo "$TS ERROR run-hook.sh: cctop-hook not found ($LABEL event=$EVENT)" >> "$LOG" 2>/dev/null
fi
