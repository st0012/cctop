#!/usr/bin/env bash
# List the sessions cctop currently tracks, one compact JSON object per line.
# Used for both the baseline snapshot and the post-launch verification.
#
# Usage: cctop-sessions.sh
#
# Output (one line per session):
#   {"pid":58384,"source":"cc","project":"cctop","status":"idle"}
# or "(no sessions)" when the directory is empty.

set -euo pipefail

dir="$HOME/.cctop/sessions"
shopt -s nullglob

found=0
for f in "$dir"/*.json; do
  found=1
  if command -v jq >/dev/null 2>&1; then
    jq -c '{pid, source, project: .project_name, status}' "$f" 2>/dev/null \
      || echo "{\"file\":\"$(basename "$f")\",\"error\":\"unparseable\"}"
  else
    # No jq available — fall back to the filename (PID-keyed) as the identity.
    basename "$f"
  fi
done

[ "$found" -eq 0 ] && echo "(no sessions)"
exit 0
