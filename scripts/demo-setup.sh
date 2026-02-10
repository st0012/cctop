#!/bin/bash
# demo-setup.sh - Creates mock sessions with realistic relative timestamps
# Usage: ./scripts/demo-setup.sh

set -e

SESSIONS_DIR="$HOME/.cctop/sessions"
mkdir -p "$SESSIONS_DIR"

# Calculate timestamps relative to now (macOS date syntax)
FIVE_SEC_AGO=$(date -u -v-5S +%Y-%m-%dT%H:%M:%SZ)
THIRTY_SEC_AGO=$(date -u -v-30S +%Y-%m-%dT%H:%M:%SZ)
TWO_MIN_AGO=$(date -u -v-2M +%Y-%m-%dT%H:%M:%SZ)
FIFTEEN_MIN_AGO=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)
ONE_HOUR_AGO=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)
SESSION_START=$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)

# Session 1: api-server - WAITING FOR PERMISSION
cat > "$SESSIONS_DIR/demo-api-server-001.json" << EOF
{
  "session_id": "demo-api-server-001",
  "project_path": "/Users/demo/projects/api-server",
  "project_name": "api-server",
  "branch": "feature/oauth2",
  "status": "waiting_permission",
  "last_prompt": "Add OAuth2 authentication with Google and GitHub providers",
  "last_activity": "$FIVE_SEC_AGO",
  "started_at": "$SESSION_START",
  "notification_message": "Allow Bash: npm test",
  "terminal": {
    "program": "iTerm.app",
    "session_id": "w0t0p0:12345",
    "tty": "/dev/ttys001"
  }
}
EOF

# Session 2: frontend-app - WAITING FOR INPUT
cat > "$SESSIONS_DIR/demo-frontend-app-002.json" << EOF
{
  "session_id": "demo-frontend-app-002",
  "project_path": "/Users/demo/projects/frontend-app",
  "project_name": "frontend-app",
  "branch": "fix/login-redirect",
  "status": "waiting_input",
  "last_prompt": "Should I also update the retry logic in the auth middleware?",
  "last_activity": "$THIRTY_SEC_AGO",
  "started_at": "$SESSION_START",
  "terminal": {
    "program": "vscode",
    "session_id": null,
    "tty": "/dev/ttys002"
  }
}
EOF

# Session 3: data-pipeline - WORKING
cat > "$SESSIONS_DIR/demo-data-pipeline-003.json" << EOF
{
  "session_id": "demo-data-pipeline-003",
  "project_path": "/Users/demo/projects/data-pipeline",
  "project_name": "data-pipeline",
  "branch": "refactor/spark-jobs",
  "status": "working",
  "last_prompt": "Refactor the ETL job to use Spark 3.5 APIs",
  "last_tool": "Bash",
  "last_tool_detail": "cargo test",
  "last_activity": "$TWO_MIN_AGO",
  "started_at": "$SESSION_START",
  "terminal": {
    "program": "iTerm.app",
    "session_id": "w0t1p0:67890",
    "tty": "/dev/ttys003"
  }
}
EOF

# Session 4: docs-site - WORKING
cat > "$SESSIONS_DIR/demo-docs-site-004.json" << EOF
{
  "session_id": "demo-docs-site-004",
  "project_path": "/Users/demo/projects/docs-site",
  "project_name": "docs-site",
  "branch": "main",
  "status": "working",
  "last_prompt": "Update the API documentation for v2 endpoints",
  "last_tool": "Edit",
  "last_tool_detail": "src/routes/auth.ts",
  "last_activity": "$FIFTEEN_MIN_AGO",
  "started_at": "$SESSION_START",
  "terminal": {
    "program": "vscode",
    "session_id": null,
    "tty": "/dev/ttys004"
  }
}
EOF

# Session 5: infra-terraform - IDLE
cat > "$SESSIONS_DIR/demo-infra-terraform-005.json" << EOF
{
  "session_id": "demo-infra-terraform-005",
  "project_path": "/Users/demo/projects/infra-terraform",
  "project_name": "infra-terraform",
  "branch": "feature/k8s-autoscaling",
  "status": "idle",
  "last_prompt": "Add horizontal pod autoscaler configuration",
  "last_activity": "$ONE_HOUR_AGO",
  "started_at": "$SESSION_START",
  "terminal": {
    "program": "Kitty",
    "session_id": "kitty-window-1",
    "tty": "/dev/ttys005"
  }
}
EOF

echo "Created 5 demo sessions in $SESSIONS_DIR"
ls -la "$SESSIONS_DIR"/demo-*.json
