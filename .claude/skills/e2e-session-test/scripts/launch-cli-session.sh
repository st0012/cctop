#!/usr/bin/env bash
# Launch an interactive CLI coding-agent session in a terminal window so cctop
# tracks it, then wait until a NEW session file appears and print it.
#
# Usage: launch-cli-session.sh <agent> [project-dir] [terminal-app]
#   agent         claude | codex | opencode | pi   (must be on your login PATH)
#   project-dir   a directory the agent already trusts (default: current dir)
#   terminal-app  GUI terminal to host it (default: Ghostty)
#
# Why the odd invocation: two pitfalls otherwise make this fail silently.
#   1. Login shell (zsh -lc): a bare exec uses a minimal PATH that often lacks
#      ~/.local/bin, so the agent binary isn't found and nothing launches.
#   2. Trusted dir: agents prompt for folder trust on first use of an unknown
#      directory and won't emit a session hook until answered — so launch in a
#      directory the user already works in.
#
# The launch line below uses macOS `open` + Ghostty's `-e`. If you use a different
# terminal, adjust the launch command for its "run this command" flag.

set -euo pipefail
# nullglob: an empty sessions dir must expand to nothing, not abort the script —
# the "no existing sessions" case is a valid baseline this test must support.
shopt -s nullglob

agent="${1:-claude}"
workdir="${2:-$PWD}"
terminal="${3:-Ghostty}"
sessions="$HOME/.cctop/sessions"

snapshot() { local f; for f in "$sessions"/*.json; do basename "$f"; done | sort; }

before="$(snapshot)"

open -na "$terminal" --args --working-directory="$workdir" -e zsh -lc "$agent"
echo "launched '$agent' in $terminal (cwd: $workdir) — waiting for cctop to register..."

for _ in $(seq 1 15); do
  sleep 1
  new="$(comm -13 <(printf '%s\n' "$before") <(snapshot) | grep -v '^$' || true)"
  if [ -n "$new" ]; then
    for f in $new; do
      echo "tracked: $f"
      if command -v jq >/dev/null 2>&1; then
        jq -c '{pid, source, project: .project_name, status}' "$sessions/$f" 2>/dev/null || true
      fi
    done
    exit 0
  fi
done

echo "FAIL: no new session registered within 15s." >&2
echo "Check ~/.cctop/logs/ and references/troubleshooting.md." >&2
exit 1
