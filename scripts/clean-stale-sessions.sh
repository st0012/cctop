#!/bin/bash
# Remove stale session files where the PID is no longer alive
# or the PID has been reused (start time mismatch).

set -euo pipefail

SESSIONS_DIR="$HOME/.cctop/sessions"

if [ ! -d "$SESSIONS_DIR" ]; then
  echo "No sessions directory found"
  exit 0
fi

removed=0

for f in "$SESSIONS_DIR"/*.json; do
  [ -f "$f" ] || continue

  pid=$(python3 -c "import json,sys; print(json.load(open('$f')).get('pid',''))")
  stored_start=$(python3 -c "import json,sys; print(json.load(open('$f')).get('pid_start_time',''))")

  if [ -z "$pid" ]; then
    continue
  fi

  alive=false
  if kill -0 "$pid" 2>/dev/null; then
    alive=true
  fi

  if $alive && [ -n "$stored_start" ]; then
    # Check PID reuse: compare stored start time with current process start time
    current_start=$(python3 -c "
import subprocess, datetime, time, sys
out = subprocess.check_output(['ps', '-p', sys.argv[1], '-o', 'lstart='], text=True).strip()
dt = datetime.datetime.strptime(out, '%a %b %d %H:%M:%S %Y')
print(f'{time.mktime(dt.timetuple()):.0f}')
" "$pid" 2>/dev/null || echo "")

    if [ -n "$current_start" ]; then
      # ps has second precision vs sysctl microseconds, so use 2s tolerance
      reused=$(python3 -c "print('yes' if abs(float('$stored_start') - float('$current_start')) > 2.0 else 'no')")
      if [ "$reused" = "yes" ]; then
        alive=false
      fi
    fi
  fi

  if ! $alive; then
    name=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('project_name','?') + ' (' + d.get('source','claude-code') + ')')")
    echo "Removing stale session: $(basename "$f") — $name"
    rm "$f"
    removed=$((removed + 1))
  fi
done

if [ "$removed" -eq 0 ]; then
  echo "No stale sessions found"
else
  echo "Removed $removed stale session(s)"
fi
