#!/bin/sh
# Validate fixture JSON files against the hook input schema.
# Uses check-jsonschema/ajv for JSON Schema validation, plus the repo's drift validator.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEMA="$ROOT_DIR/hook-input.schema.json"
FIXTURES_DIR="$ROOT_DIR/fixtures"
CONTRACT_VALIDATOR="$SCRIPT_DIR/validate-hook-contract.py"

if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$SCHEMA" "$FIXTURES_DIR"/*.json
elif command -v npx >/dev/null 2>&1 && npx --no-install ajv-cli help >/dev/null 2>&1; then
    npx --no-install ajv-cli validate --strict=false -s "$SCHEMA" -d "$FIXTURES_DIR/*.json"
else
    echo "ERROR: install check-jsonschema or a local ajv-cli for schema validation" >&2
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    python3 "$CONTRACT_VALIDATOR" fixtures
else
    echo "ERROR: install python3 for fixture contract validation" >&2
    exit 1
fi

echo "All fixtures valid against schema."
