#!/bin/bash
# demo-cleanup.sh - Removes demo sessions
# Usage: ./scripts/demo-cleanup.sh

SESSIONS_DIR="$HOME/.cctop/sessions"

rm -f "$SESSIONS_DIR"/demo-*.json
echo "Cleaned up demo sessions"
