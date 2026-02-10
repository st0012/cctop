---
name: qa-menubar
description: Run visual QA on the menubar app. Generates snapshots for various session scenarios and reviews them for UI issues.
---

# Menubar QA Skill

Runs visual QA on the CctopMenubar SwiftUI app by generating snapshot images for different session configurations and reviewing each one.

## When to Use

- After making visual changes to PopupView, HeaderView, SessionCardView, or StatusChip
- When debugging layout or badge count issues
- Before releasing menubar app changes

## Steps

### Step 1: Run QA snapshot tests

Use the XcodeBuildMCP `test_macos` tool to run only the QA snapshot tests:

```
test_macos with extraArgs: ["-only-testing:CctopMenubarTests/QASnapshotTests"]
```

Or via bash if XcodeBuildMCP is unavailable:

```bash
xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
  -only-testing:CctopMenubarTests/QASnapshotTests \
  -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
```

### Step 2: Review each snapshot

Read each PNG from `/tmp/cctop-qa/` and check for issues:

```
/tmp/cctop-qa/01-empty.png
/tmp/cctop-qa/02-single.png
/tmp/cctop-qa/03-four-sessions.png
/tmp/cctop-qa/04-five-sessions.png
/tmp/cctop-qa/05-six-sessions.png
/tmp/cctop-qa/06-eight-sessions.png
/tmp/cctop-qa/07-all-attention.png
/tmp/cctop-qa/08-all-idle.png
/tmp/cctop-qa/09-long-names.png
/tmp/cctop-qa/10-five-sessions-dark.png
```

### Step 3: Check each scenario against its expected behavior

| # | Scenario | What to verify |
|---|----------|----------------|
| 01 | Empty | Shows "No active sessions" text, no badge chips in header |
| 02 | Single session | One badge chip visible (green for working), card renders correctly |
| 03 | Four sessions | Baseline — badges show 2 amber, 1 green, 1 gray. All 4 cards visible |
| 04 | Five sessions | **Key test** — badges show 2 amber, 2 green, 1 gray. All 5 cards visible, no clipping |
| 05 | Six sessions | Badges show 2 amber, 2 green, 2 gray. All 6 cards visible |
| 06 | Eight sessions | Badges show 3 amber, 3 green, 2 gray. Scroll area should contain all 8 cards (may need scroll) |
| 07 | All attention | Only amber badge visible. Green and gray badges hidden (count = 0) |
| 08 | All idle | Only gray badge visible. Amber and green badges hidden |
| 09 | Long names | Project names and branch labels truncate gracefully, no layout overflow |
| 10 | Five sessions (dark) | Same as #04 but in dark mode. Colors render correctly, text is readable |

### Step 4: Report findings

Summarize which scenarios pass and which have issues. For any failures, describe:
- What was expected vs what was rendered
- Which view/component is likely responsible
- Suggested fix direction
