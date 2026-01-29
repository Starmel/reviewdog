#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Cleanup ==="

# Remove temp files
rm -f "$SCRIPT_DIR/.mr_info"
rm -rf "$TEST_REPO_DIR"

info "Temp files removed"

# Optionally stop GitLab (uncomment if needed)
# docker stop gitlab
# info "GitLab stopped"

echo "Cleanup complete"
