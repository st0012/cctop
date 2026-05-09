#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPCAST="${1:-$REPO_ROOT/appcast.xml}"

python3 - "$APPCAST" << 'PYEOF'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
errors = []

tree = ET.parse(path)
channel = tree.getroot().find("channel")
if channel is None:
    errors.append("missing channel")
else:
    latest_title = None
    for item in channel.findall("item"):
        title = (item.findtext("title") or "<untitled>").strip()
        if latest_title is None:
            latest_title = title
        elif title != latest_title:
            break

        enclosures = item.findall("enclosure")
        cpu_enclosures = [
            enclosure
            for enclosure in enclosures
            if enclosure.get(f"{sparkle}cpu") in {"arm64", "x86_64"}
        ]

        if len(cpu_enclosures) > 1:
            cpus = ", ".join(enclosure.get(f"{sparkle}cpu") or "unspecified" for enclosure in cpu_enclosures)
            errors.append(f"{title}: has multiple CPU-specific enclosures in one item ({cpus})")

        if cpu_enclosures:
            cpu = cpu_enclosures[0].get(f"{sparkle}cpu")
            hardware = (item.findtext(f"{sparkle}hardwareRequirements") or "").strip()
            if cpu == "arm64" and hardware != "arm64":
                errors.append(f"{title}: arm64 enclosure must be in an arm64 hardware-restricted item")
            if cpu == "x86_64" and hardware:
                errors.append(f"{title}: x86_64 enclosure must not inherit hardware requirements ({hardware})")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    sys.exit(1)

print("OK: appcast architecture items are valid")
PYEOF
