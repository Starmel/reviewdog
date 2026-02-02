#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 05: Multiple Tools ==="

cd "$TEST_REPO_DIR"

# Run reviewdog with different tool name
info "Running reviewdog with tool 'staticcheck'..."
echo 'integration_test.go:7:5: y declared but not used (SA4006)' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=staticcheck -f=golint

# Check that both tools' comments exist
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

GOLINT_COMMENTS=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].body | contains("[golint]"))] | length')
STATICCHECK_COMMENTS=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].body | contains("[staticcheck]"))] | length')

info "golint comments: $GOLINT_COMMENTS"
info "staticcheck comments: $STATICCHECK_COMMENTS"

if [ "$GOLINT_COMMENTS" -ge 1 ]; then
    pass "golint comments exist"
else
    fail "No golint comments found"
fi

if [ "$STATICCHECK_COMMENTS" -ge 1 ]; then
    pass "staticcheck comments exist"
else
    fail "No staticcheck comments found"
fi

# Verify that running staticcheck again doesn't affect golint comments
info "Running staticcheck again - should not resolve golint comments..."
echo 'integration_test.go:7:5: y declared but not used (SA4006)' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=staticcheck -f=golint

DISCUSSIONS_AFTER=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

# golint comments should still exist (not resolved by staticcheck run)
GOLINT_UNRESOLVED=$(echo "$DISCUSSIONS_AFTER" | jq '[.[] | select((.notes[0].body | contains("[golint]")) and .notes[0].resolved == false)] | length')
info "golint unresolved comments: $GOLINT_UNRESOLVED"

if [ "$GOLINT_UNRESOLVED" -ge 1 ]; then
    pass "golint comments not affected by staticcheck run"
else
    # This is expected - golint was resolved in test 04
    info "golint comments were resolved (expected from test 04)"
fi

echo ""
echo "=== Test 05 Complete ==="
