# Demo recording for cctop README
# Prerequisites:
#   1. cargo install --path .
#   2. ./scripts/demo-setup.sh
# Run with: vhs docs/demo.tape
# Cleanup after: ./scripts/demo-cleanup.sh

Output docs/demo.gif
Set FontSize 14
Set Width 900
Set Height 600
Set Theme "Dracula"

# Set demo mode to skip liveness checks for mock sessions
# Note: Env must come after Set commands
Env CCTOP_DEMO "1"

# Launch cctop
Type "cctop"
Enter
Sleep 2s

# Show the initial view with all 5 sessions across 4 categories:
# WAITING FOR PERMISSION: api-server (Allow Bash: npm test)
# WAITING FOR INPUT: frontend-app (asking a question)
# WORKING: data-pipeline (Running: cargo test), docs-site (Editing auth.ts)
# IDLE: infra-terraform

# Pause to let the viewer see the full layout
Sleep 2s

# Navigate down through sessions
Down
Sleep 600ms
Down
Sleep 600ms
Down
Sleep 600ms
Down
Sleep 600ms

# Now at infra-terraform (last session)
# Navigate back up to the top
Up
Sleep 600ms
Up
Sleep 600ms
Up
Sleep 600ms
Up
Sleep 600ms

# Back at api-server - show detail view
Right
Sleep 2s

# Return to list
Left
Sleep 1s

# Quit
Type "q"
Sleep 300ms
