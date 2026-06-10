#!/usr/bin/env python3
"""Validate cctop hook contract drift across schema, fixtures, Swift, and plugins.

The JSON Schema remains the source of truth. This script intentionally stays
narrow: it checks that consumers agree with schema-owned event, harness, and
cctop-hook binary-location metadata, while validate-fixtures.sh handles full
fixture schema validation.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "hook-input.schema.json"
FIXTURES = ROOT / "fixtures"
HOOK_EVENT_SWIFT = ROOT / "menubar/CctopMenubar/Models/HookEvent.swift"
HOOK_INPUT_SWIFT = ROOT / "menubar/CctopMenubar/Hook/HookInput.swift"
CODEX_INSTALLER_SWIFT = ROOT / "menubar/CctopMenubar/Services/CodexPluginInstaller.swift"
CC_HOOKS_JSON = ROOT / "plugins/cctop/hooks/hooks.json"
CODEX_HOOKS_JSON = ROOT / "plugins/codex/hooks.json"
CC_SHIM = ROOT / "plugins/cctop/hooks/run-hook.sh"
CODEX_SHIM = ROOT / "plugins/codex/cctop-shim.sh"
OPENCODE_PLUGIN = ROOT / "plugins/opencode/plugin.js"
PI_PLUGIN = ROOT / "plugins/pi/cctop.ts"


def load_json(path: Path) -> object:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def expect(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def compare_sets(label: str, expected: set[str], actual: set[str], errors: list[str]) -> None:
    if expected == actual:
        return

    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    parts = []
    if missing:
        parts.append(f"missing={missing}")
    if extra:
        parts.append(f"extra={extra}")
    errors.append(f"{label} drifted: {', '.join(parts)}")


def quoted_strings(text: str) -> set[str]:
    return set(re.findall(r'"([^"]+)"', text))


def schema_contract(errors: list[str]) -> tuple[set[str], set[str], dict[str, set[str]], list[str]]:
    schema = load_json(SCHEMA)
    if not isinstance(schema, dict):
        errors.append("hook-input.schema.json must be a JSON object")
        return set(), set(), {}, []

    properties = schema.get("properties", {})
    if not isinstance(properties, dict):
        errors.append("schema properties must be an object")
        return set(), set(), {}, []

    event_schema = properties.get("hook_event_name", {})
    events = set(event_schema.get("enum", [])) if isinstance(event_schema, dict) else set()
    expect(bool(events), "schema hook_event_name must define an enum", errors)

    harness_schema = properties.get("harness_name")
    expect(isinstance(harness_schema, dict), "schema must define harness_name", errors)
    harnesses = (
        set(harness_schema.get("enum", []))
        if isinstance(harness_schema, dict) and isinstance(harness_schema.get("enum"), list)
        else set()
    )
    expect(bool(harnesses), "schema harness_name must define an enum", errors)

    source_schema = properties.get("source", {})
    expect(isinstance(source_schema, dict), "schema must preserve legacy source", errors)
    if isinstance(source_schema, dict):
        expect(
            "source" not in schema.get("required", []),
            "legacy source must remain optional",
            errors,
        )

    metadata = schema.get("x-cctop")
    expect(isinstance(metadata, dict), "schema must define x-cctop contract metadata", errors)
    if not isinstance(metadata, dict):
        return events, harnesses, {}, []

    metadata_harnesses = set(metadata.get("harnesses", []))
    compare_sets("x-cctop harnesses", harnesses, metadata_harnesses, errors)

    raw_binary_locations = metadata.get("binary_locations")
    expect(
        isinstance(raw_binary_locations, list) and bool(raw_binary_locations),
        "x-cctop binary_locations must be a non-empty array",
        errors,
    )
    binary_locations: list[str] = []
    if isinstance(raw_binary_locations, list):
        for location in raw_binary_locations:
            if isinstance(location, str) and (location.startswith("~/") or location.startswith("/")):
                binary_locations.append(location)
            else:
                errors.append(
                    f"x-cctop binary_locations entry {location!r} must be a string starting with ~/ or /"
                )

    raw_harness_events = metadata.get("events_by_harness", {})
    expect(isinstance(raw_harness_events, dict), "x-cctop events_by_harness must be an object", errors)
    harness_events: dict[str, set[str]] = {}
    if isinstance(raw_harness_events, dict):
        for harness, event_list in raw_harness_events.items():
            harness_events[harness] = set(event_list) if isinstance(event_list, list) else set()
        compare_sets("events_by_harness keys", harnesses, set(harness_events), errors)
        for harness, event_names in sorted(harness_events.items()):
            expect(bool(event_names), f"{harness} events_by_harness must not be empty", errors)
            expect(
                event_names <= events,
                f"{harness} events_by_harness contains events outside schema: {sorted(event_names - events)}",
                errors,
            )

    return events, harnesses, harness_events, binary_locations


def fixture_contract(
    schema_events: set[str],
    harnesses: set[str],
    harness_events: dict[str, set[str]],
    errors: list[str],
) -> None:
    seen_events: set[str] = set()
    for path in sorted(FIXTURES.glob("*.json")):
        payload = load_json(path)
        if not isinstance(payload, dict):
            errors.append(f"{path.relative_to(ROOT)} must be a JSON object")
            continue

        for field in ("session_id", "cwd", "hook_event_name"):
            expect(field in payload, f"{path.relative_to(ROOT)} missing required {field}", errors)

        event = payload.get("hook_event_name")
        expect(isinstance(event, str), f"{path.relative_to(ROOT)} hook_event_name must be a string", errors)
        if isinstance(event, str):
            seen_events.add(event)
            expect(
                event in schema_events,
                f"{path.relative_to(ROOT)} event {event!r} not in schema enum",
                errors,
            )

        harness = payload.get("harness_name")
        if harness is not None:
            expect(
                harness in harnesses,
                f"{path.relative_to(ROOT)} harness_name {harness!r} not in schema enum",
                errors,
            )
            if isinstance(harness, str) and isinstance(event, str) and harness in harness_events:
                expect(
                    event in harness_events[harness],
                    f"{path.relative_to(ROOT)} event {event!r} not in {harness} event subset",
                    errors,
                )

    compare_sets("fixture event coverage", schema_events, seen_events, errors)


def swift_events(schema_events: set[str], errors: list[str]) -> None:
    text = read_text(HOOK_EVENT_SWIFT)
    mapped = set(re.findall(r'"([^"]+)":\s*\.', text))
    if 'hookName == "Notification"' in text:
        mapped.add("Notification")
    compare_sets("Swift HookEvent events", schema_events, mapped, errors)


def swift_harnesses(harnesses: set[str], errors: list[str]) -> None:
    text = read_text(HOOK_INPUT_SWIFT)
    match = re.search(r"knownHarnesses:\s*Set<String>\s*=\s*\[([^\]]*)\]", text)
    expect(match is not None, "HookInput.swift must define knownHarnesses", errors)
    if match:
        compare_sets("HookInput knownHarnesses", harnesses, quoted_strings(match.group(1)), errors)


def hook_commands(value: object) -> list[str]:
    if isinstance(value, dict):
        commands = []
        command = value.get("command")
        if isinstance(command, str):
            commands.append(command)
        for nested in value.values():
            commands.extend(hook_commands(nested))
        return commands
    if isinstance(value, list):
        commands = []
        for item in value:
            commands.extend(hook_commands(item))
        return commands
    return []


def hooks_json_events(path: Path, errors: list[str]) -> set[str]:
    payload = load_json(path)
    if not isinstance(payload, dict) or not isinstance(payload.get("hooks"), dict):
        return set()
    hooks = payload["hooks"]
    for event, entries in hooks.items():
        invoked = set()
        for command in hook_commands(entries):
            match = re.search(r"(?:run-hook\.sh|\{SHIM\})\s+([A-Za-z]+)", command)
            if match:
                invoked.add(match.group(1))
        compare_sets(f"{path.relative_to(ROOT)} commands for {event}", {event}, invoked, errors)
    return set(hooks)


def call_hook_events(path: Path) -> set[str]:
    return set(re.findall(r"callHook\([^,\n]+,\s*\"([A-Za-z]+)\"", read_text(path)))


def cli_harness_args(path: Path) -> set[str]:
    return set(re.findall(r"--harness\s+([A-Za-z0-9_-]+)", read_text(path)))


def payload_harness_names(path: Path) -> set[str]:
    return set(re.findall(r'harness_name:\s*"([^"]+)"', read_text(path)))


def plugin_contract(harnesses: set[str], harness_events: dict[str, set[str]], errors: list[str]) -> None:
    plugin_ids = set()
    plugin_ids |= cli_harness_args(CC_SHIM)
    plugin_ids |= cli_harness_args(CODEX_SHIM)
    plugin_ids |= payload_harness_names(OPENCODE_PLUGIN)
    plugin_ids |= payload_harness_names(PI_PLUGIN)
    compare_sets("plugin harness IDs", harnesses, plugin_ids, errors)

    actual_events = {
        "cc": hooks_json_events(CC_HOOKS_JSON, errors),
        "codex": hooks_json_events(CODEX_HOOKS_JSON, errors),
        "opencode": call_hook_events(OPENCODE_PLUGIN),
        "pi": call_hook_events(PI_PLUGIN),
    }
    for harness, events in sorted(actual_events.items()):
        compare_sets(f"{harness} hook events", harness_events.get(harness, set()), events, errors)

    installer = read_text(CODEX_INSTALLER_SWIFT)
    match = re.search(r"registeredEvents:\s*\[String\]\s*=\s*\[([^\]]*)\]", installer)
    expect(match is not None, "CodexPluginInstaller.swift must define registeredEvents", errors)
    if match:
        compare_sets(
            "Codex installer events",
            harness_events.get("codex", set()),
            quoted_strings(match.group(1)),
            errors,
        )


def binary_location_contract(binary_locations: list[str], errors: list[str]) -> None:
    """Require every client to look for cctop-hook at the schema-owned discovery locations.

    Home-relative (~/) locations must appear anchored to the home directory ($HOME/ in
    shell, homedir() in JS/TS) so the bare /Applications entry cannot satisfy the
    ~/Applications check. Absolute locations must appear verbatim and not as the tail of
    a $HOME-prefixed path, so the ~/Applications entry cannot satisfy the bare one either.
    """
    clients = [CC_SHIM, CODEX_SHIM, OPENCODE_PLUGIN, PI_PLUGIN]
    for client in clients:
        text = read_text(client)
        for location in binary_locations:
            if location.startswith("~/"):
                suffix = re.escape(location[2:])
                pattern = r'(\$HOME/|homedir\(\), ?")' + suffix
            else:
                pattern = r"(?<!\$HOME)" + re.escape(location)
            expect(
                re.search(pattern, text) is not None,
                f"{client.relative_to(ROOT)} does not look for cctop-hook at {location}",
                errors,
            )


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    if mode not in {"all", "fixtures", "hooks"}:
        print("usage: validate-hook-contract.py [all|fixtures|hooks]", file=sys.stderr)
        return 2

    errors: list[str] = []
    schema_events, harnesses, harness_events, binary_locations = schema_contract(errors)
    if mode in {"all", "fixtures"}:
        fixture_contract(schema_events, harnesses, harness_events, errors)
    if mode in {"all", "hooks"}:
        swift_events(schema_events, errors)
        swift_harnesses(harnesses, errors)
        plugin_contract(harnesses, harness_events, errors)
        binary_location_contract(binary_locations, errors)

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Hook contract matches schema, fixtures, Swift, and plugins.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
