#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 07: Empty Tool Name ==="

cd "$TEST_REPO_DIR"

# Run reviewdog WITHOUT -name flag (empty tool name)
info "Running reviewdog without tool name..."
echo 'integration_test.go:5:1: missing package comment' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -f=golint

# Check comment was created
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

COMMENT=$(echo "$DISCUSSIONS" | jq -r '[.[] | select(.notes[0].body | contains("missing package comment"))] | .[0].notes[0].body // empty')

if [ -n "$COMMENT" ]; then
    pass "Comment created without tool name"
else
    fail "Comment not created"
fi

# Verify meta comment still exists
if echo "$COMMENT" | grep -q "<!-- __reviewdog__:"; then
    pass "Meta comment present even without tool name"
else
    fail "Meta comment missing"
fi

echo ""
echo "=== Test 07 Complete ==="
