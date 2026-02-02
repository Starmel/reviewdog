#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 02: Post Comment via reviewdog ==="

# Setup test repo
info "Setting up test repository..."
rm -rf "$TEST_REPO_DIR"
git clone "http://root:$GITLAB_TOKEN@localhost:8080/root/test-reviewdog.git" "$TEST_REPO_DIR" 2>/dev/null
cd "$TEST_REPO_DIR"
git fetch origin feature-integration-test
git checkout feature-integration-test

# Build reviewdog if needed
if [ ! -f "$REVIEWDOG_BIN" ]; then
    info "Building reviewdog..."
    cd "$SCRIPT_DIR/.."
    go build -o reviewdog ./cmd/reviewdog/
    cd "$TEST_REPO_DIR"
fi

# Clear existing discussions
info "Getting initial discussion count..."
INITIAL_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')
info "Initial discussions: $INITIAL_COUNT"

# Run reviewdog with lint output
info "Running reviewdog with lint output..."
echo 'integration_test.go:8:5: z declared but not used' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=golint -f=golint

# Check if comment was created
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

NEW_COUNT=$(echo "$DISCUSSIONS" | jq 'length')
info "Discussions after reviewdog: $NEW_COUNT"

if [ "$NEW_COUNT" -gt "$INITIAL_COUNT" ]; then
    pass "Comment posted successfully"
else
    fail "No new comment was created"
fi

# Verify comment content
LAST_COMMENT=$(echo "$DISCUSSIONS" | jq -r '.[-1].notes[0].body')
if echo "$LAST_COMMENT" | grep -q "z declared but not used"; then
    pass "Comment contains expected message"
else
    fail "Comment does not contain expected message: $LAST_COMMENT"
fi

# Verify meta comment exists
if echo "$LAST_COMMENT" | grep -q "<!-- __reviewdog__:"; then
    pass "Comment contains meta information (fingerprint)"
else
    fail "Comment missing meta information"
fi

echo ""
echo "=== Test 02 Complete ==="
