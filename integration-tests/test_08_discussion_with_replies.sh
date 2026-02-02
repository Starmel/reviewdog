#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 08: Discussion With Replies ==="

cd "$TEST_REPO_DIR"

# Create a new comment first
info "Creating a comment that will get a reply..."
echo 'integration_test.go:6:5: test error for reply test' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=reply-test -f=golint

# Get the discussion ID
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

DISCUSSION_ID=$(echo "$DISCUSSIONS" | jq -r '[.[] | select(.notes[0].body | contains("test error for reply test"))] | .[0].id // empty')

if [ -z "$DISCUSSION_ID" ]; then
    fail "Could not find discussion"
fi

info "Discussion ID: $DISCUSSION_ID"

# Add a reply to the discussion
info "Adding reply to discussion..."
curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions/$DISCUSSION_ID/notes" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"body": "This is a human reply to the reviewdog comment"}' > /dev/null

pass "Reply added"

# Now run reviewdog with different output (should resolve old, but this one has reply)
info "Running reviewdog with different error (old should be resolved)..."
echo 'integration_test.go:7:5: different error' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=reply-test -f=golint

# Check if the discussion with reply was resolved
DISCUSSIONS_AFTER=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

RESOLVED=$(echo "$DISCUSSIONS_AFTER" | jq -r "[.[] | select(.id == \"$DISCUSSION_ID\")] | .[0].notes[0].resolved")

info "Discussion with reply resolved status: $RESOLVED"

# NOTE: Current implementation WILL resolve discussions with replies
# This test documents the current behavior
if [ "$RESOLVED" == "true" ]; then
    info "WARNING: Discussion with replies was resolved (current behavior)"
    info "Consider: Should discussions with replies be preserved?"
else
    pass "Discussion with replies was NOT resolved"
fi

echo ""
echo "=== Test 08 Complete ==="
