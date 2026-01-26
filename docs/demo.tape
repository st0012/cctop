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

# Show the initial view with all 5 sessions across 3 categories
# NEEDS ATTENTION: api-server
# WORKING: frontend-app, data-pipeline
# IDLE: docs-site, infra-terraform

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
# Navigate back up
Up
Sleep 600ms
Up
Sleep 600ms
Up
Sleep 600ms

# Back at frontend-app
# Refresh
Type "r"
Sleep 800ms

# Quit
Type "q"
Sleep 300ms
