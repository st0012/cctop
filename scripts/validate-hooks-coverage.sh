#!/bin/sh
# Verify hook contract coverage across schema, Swift, fixtures, and plugins.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTRACT_VALIDATOR="$SCRIPT_DIR/validate-hook-contract.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: install python3 for hook contract validation" >&2
    exit 1
fi

python3 "$CONTRACT_VALIDATOR" hooks
