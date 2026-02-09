#!/bin/bash
# Generate the cctop state machine diagram as SVG
# Requires: graphviz (brew install graphviz)

set -euo pipefail

OUTPUT="${1:-/tmp/cctop-states.svg}"

if ! command -v dot &>/dev/null; then
  echo "Error: graphviz not installed. Run: brew install graphviz" >&2
  exit 1
fi

cctop --dot | dot -Tsvg -o "$OUTPUT"
echo "State diagram written to $OUTPUT"
open "$OUTPUT"
