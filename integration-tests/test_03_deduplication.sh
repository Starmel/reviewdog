#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 03: Comment Deduplication ==="

cd "$TEST_REPO_DIR"

# Get current discussion count
info "Getting current discussion count..."
BEFORE_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')
info "Discussions before: $BEFORE_COUNT"

# Run reviewdog with SAME lint output (should NOT create duplicate)
info "Running reviewdog with same lint output..."
echo 'integration_test.go:8:5: z declared but not used' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=golint -f=golint

# Check discussion count - should be the same
AFTER_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')
info "Discussions after: $AFTER_COUNT"

if [ "$AFTER_COUNT" -eq "$BEFORE_COUNT" ]; then
    pass "No duplicate comment created"
else
    fail "Duplicate comment was created (before: $BEFORE_COUNT, after: $AFTER_COUNT)"
fi

# Run 3 more times to be sure
info "Running reviewdog 3 more times..."
for i in 1 2 3; do
    echo 'integration_test.go:8:5: z declared but not used' | \
        "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=golint -f=golint
done

FINAL_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')

if [ "$FINAL_COUNT" -eq "$BEFORE_COUNT" ]; then
    pass "Deduplication works correctly after multiple runs"
else
    fail "Duplicates created after multiple runs (before: $BEFORE_COUNT, final: $FINAL_COUNT)"
fi

echo ""
echo "=== Test 03 Complete ==="
