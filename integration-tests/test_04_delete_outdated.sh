#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 04: Delete Outdated Discussions ==="
echo "Tests that outdated comments are DELETED (not resolved)"
echo "DELETE does not send email notifications"

cd "$TEST_REPO_DIR"

# Get current discussions
info "Getting current discussions..."
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

# Count discussions with golint meta-comment (from reviewdog)
GOLINT_DISCUSSIONS_BEFORE=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].body | contains("golint"))] | length')
info "Discussions with golint before: $GOLINT_DISCUSSIONS_BEFORE"

# Run reviewdog with DIFFERENT lint output (simulating fix + new issue)
info "Running reviewdog with different lint output (simulating issue fix)..."
echo 'integration_test.go:6:5: x declared but not used' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=golint -f=golint

# Check discussions
DISCUSSIONS_AFTER=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

# Old discussion (line 8, z) should be DELETED (not present)
OLD_EXISTS=$(echo "$DISCUSSIONS_AFTER" | jq '[.[] | select(.notes[0].body | contains("z declared"))] | length')
if [ "$OLD_EXISTS" -eq 0 ]; then
    pass "Old discussion (z declared) was DELETED"
else
    fail "Old discussion should be deleted but still exists"
fi

# New discussion (line 6, x) should exist and be unresolved
NEW_EXISTS=$(echo "$DISCUSSIONS_AFTER" | jq '[.[] | select(.notes[0].body | contains("x declared"))] | length')
if [ "$NEW_EXISTS" -eq 1 ]; then
    pass "New discussion (x declared) was created"
else
    fail "New discussion should exist, found $NEW_EXISTS"
fi

NEW_RESOLVED=$(echo "$DISCUSSIONS_AFTER" | jq '[.[] | select(.notes[0].body | contains("x declared"))] | .[0].notes[0].resolved')
if [ "$NEW_RESOLVED" == "false" ] || [ "$NEW_RESOLVED" == "null" ]; then
    pass "New discussion (x declared) is unresolved"
else
    fail "New discussion should be unresolved: $NEW_RESOLVED"
fi

info "NOTE: DELETE operation does NOT send email notifications"

echo ""
echo "=== Test 04 Complete ==="
