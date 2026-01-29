#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 04: Resolve Outdated Discussions ==="

cd "$TEST_REPO_DIR"

# Get current discussions
info "Getting current discussions..."
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

UNRESOLVED_BEFORE=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].resolved == false)] | length')
info "Unresolved discussions before: $UNRESOLVED_BEFORE"

# Run reviewdog with DIFFERENT lint output (simulating fix + new issue)
info "Running reviewdog with different lint output (simulating issue fix)..."
echo 'integration_test.go:6:5: x declared but not used' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=golint -f=golint

# Check discussions
DISCUSSIONS_AFTER=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

# Old discussion (line 8, z) should be resolved
OLD_RESOLVED=$(echo "$DISCUSSIONS_AFTER" | jq '[.[] | select(.notes[0].body | contains("z declared"))] | .[0].notes[0].resolved')
if [ "$OLD_RESOLVED" == "true" ]; then
    pass "Old discussion (z declared) was resolved"
else
    fail "Old discussion was not resolved: $OLD_RESOLVED"
fi

# New discussion (line 6, x) should be unresolved
NEW_RESOLVED=$(echo "$DISCUSSIONS_AFTER" | jq '[.[] | select(.notes[0].body | contains("x declared"))] | .[0].notes[0].resolved')
if [ "$NEW_RESOLVED" == "false" ]; then
    pass "New discussion (x declared) is unresolved"
else
    fail "New discussion should be unresolved: $NEW_RESOLVED"
fi

echo ""
echo "=== Test 04 Complete ==="
