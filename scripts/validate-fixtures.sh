#!/bin/sh
# Validate fixture JSON files against the hook input schema.
# Requires: pip3 install check-jsonschema (or npx ajv-cli)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEMA="$ROOT_DIR/hook-input.schema.json"
FIXTURES_DIR="$ROOT_DIR/fixtures"

if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$SCHEMA" "$FIXTURES_DIR"/*.json
elif command -v npx >/dev/null 2>&1; then
    npx --yes ajv-cli validate -s "$SCHEMA" -d "$FIXTURES_DIR/*.json"
else
    echo "ERROR: install check-jsonschema or npm for schema validation" >&2
    exit 1
fi

echo "All fixtures valid against schema."
