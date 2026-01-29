#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 10: Large Batch of Comments ==="

cd "$TEST_REPO_DIR"

# Generate 20 different errors
info "Generating 20 lint errors..."
ERRORS=""
for i in $(seq 1 20); do
    line=$((5 + (i % 5)))  # Lines 5-9
    ERRORS+="integration_test.go:${line}:${i}: batch error number $i"$'\n'
done

BEFORE_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')

info "Discussions before: $BEFORE_COUNT"
info "Posting 20 comments in batch..."

START_TIME=$(date +%s)
echo "$ERRORS" | "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=batch-test -f=golint
END_TIME=$(date +%s)

DURATION=$((END_TIME - START_TIME))
info "Batch post took: ${DURATION}s"

AFTER_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')

NEW_COMMENTS=$((AFTER_COUNT - BEFORE_COUNT))
info "New discussions created: $NEW_COMMENTS"

if [ "$NEW_COMMENTS" -ge 15 ]; then  # Allow some to be on same line
    pass "Batch posting works ($NEW_COMMENTS comments created)"
else
    fail "Expected ~20 comments, got $NEW_COMMENTS"
fi

# Test deduplication of batch
info "Running same batch again..."
echo "$ERRORS" | "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=batch-test -f=golint

FINAL_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')

if [ "$FINAL_COUNT" -eq "$AFTER_COUNT" ]; then
    pass "Batch deduplication works"
else
    fail "Duplicates created in batch (after: $AFTER_COUNT, final: $FINAL_COUNT)"
fi

echo ""
echo "=== Test 10 Complete ==="
