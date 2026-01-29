#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 09: Same Line, Different Messages ==="

cd "$TEST_REPO_DIR"

# Post first comment on line 6
info "Posting first comment on line 6..."
echo 'integration_test.go:6:5: error type A' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=multi-error -f=golint

# Post second comment on same line with different message
info "Posting second comment on same line 6..."
echo 'integration_test.go:6:5: error type B' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=multi-error -f=golint

# Check both comments exist
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

ERROR_A=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].body | contains("error type A"))] | length')
ERROR_B=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].body | contains("error type B"))] | length')

info "Comments with 'error type A': $ERROR_A"
info "Comments with 'error type B': $ERROR_B"

if [ "$ERROR_A" -ge 1 ] && [ "$ERROR_B" -ge 1 ]; then
    pass "Both different messages on same line exist"
else
    fail "Expected both messages to exist"
fi

# Run again - should not create duplicates
info "Running again - checking no duplicates..."
echo -e 'integration_test.go:6:5: error type A\nintegration_test.go:6:5: error type B' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=multi-error -f=golint

DISCUSSIONS_AFTER=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

ERROR_A_AFTER=$(echo "$DISCUSSIONS_AFTER" | jq '[.[] | select(.notes[0].body | contains("error type A"))] | length')
ERROR_B_AFTER=$(echo "$DISCUSSIONS_AFTER" | jq '[.[] | select(.notes[0].body | contains("error type B"))] | length')

if [ "$ERROR_A_AFTER" -eq "$ERROR_A" ] && [ "$ERROR_B_AFTER" -eq "$ERROR_B" ]; then
    pass "No duplicates created"
else
    fail "Duplicates created (A: $ERROR_A -> $ERROR_A_AFTER, B: $ERROR_B -> $ERROR_B_AFTER)"
fi

echo ""
echo "=== Test 09 Complete ==="
