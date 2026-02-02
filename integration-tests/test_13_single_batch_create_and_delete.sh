#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow override of GITLAB_TOKEN before sourcing config
GITLAB_TOKEN_OVERRIDE="${GITLAB_TOKEN:-}"
source "$SCRIPT_DIR/config.sh"
if [ -n "$GITLAB_TOKEN_OVERRIDE" ]; then
    export GITLAB_TOKEN="$GITLAB_TOKEN_OVERRIDE"
    export REVIEWDOG_GITLAB_API_TOKEN="$GITLAB_TOKEN"
fi

echo "=== Test 13: Single Batch Create and Delete ==="
echo "Tests that new comments are created and old comments are DELETED (not resolved)"
echo "DELETE does not send email notifications"

# Create a fresh MR for this test
info "Creating fresh MR for delete test..."

# Delete old branch if exists
curl -s -X DELETE "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/branches/feature-single-batch" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" > /dev/null 2>&1 || true

# Create new branch
curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/branches" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"branch": "feature-single-batch", "ref": "main"}' > /dev/null

# Create test file
FILE_CONTENT='package main

func main() {
    old1 := 1
    old2 := 2
    old3 := 3
}
'
curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/files/single_batch_test.go" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg content "$FILE_CONTENT" '{
        branch: "feature-single-batch",
        content: $content,
        commit_message: "Add single_batch_test.go"
    }')" > /dev/null

# Create MR
MR_RESULT=$(curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "source_branch": "feature-single-batch",
        "target_branch": "main",
        "title": "Single Batch Test MR"
    }')

MR_IID=$(echo "$MR_RESULT" | jq -r '.iid')
MR_SHA=$(echo "$MR_RESULT" | jq -r '.sha')
pass "MR created: IID=$MR_IID"

# Clone repo (use password for git, not token)
GIT_PASSWORD="${GITLAB_PASSWORD:-ReviewDog123!}"
rm -rf "$TEST_REPO_DIR"
git clone "http://root:$GIT_PASSWORD@${GITLAB_HOST:-localhost:8080}/root/test-reviewdog.git" "$TEST_REPO_DIR" 2>/dev/null
cd "$TEST_REPO_DIR"
git fetch origin feature-single-batch
git checkout feature-single-batch

export CI_PULL_REQUEST="$MR_IID"
export CI_COMMIT="$MR_SHA"

# Step 1: Create initial comments (3 "old" issues)
info "Step 1: Creating 3 initial comments..."
echo -e 'single_batch_test.go:4:5: unused old1\nsingle_batch_test.go:5:5: unused old2\nsingle_batch_test.go:6:5: unused old3' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=batch-test -f=golint

# Filter only code comments (with position), exclude system notes
INITIAL_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq '[.[] | select(.notes[0].position != null)] | length')
info "Initial code discussions: $INITIAL_COUNT"

if [ "$INITIAL_COUNT" -ne 3 ]; then
    fail "Expected 3 initial discussions, got $INITIAL_COUNT"
fi
pass "3 initial comments created"

# Step 2: Add a manual user comment (should NOT be deleted by reviewdog)
info "Step 2: Adding manual user discussion (not from reviewdog)..."
MR_INFO=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")
TARGET_SHA=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/branches/main" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq -r '.commit.id')

curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg body "This is a manual user comment - should NOT be auto-deleted!" \
        --arg base "$TARGET_SHA" \
        --arg head "$MR_SHA" \
        '{
            body: $body,
            position: {
                base_sha: $base,
                start_sha: $base,
                head_sha: $head,
                position_type: "text",
                new_path: "single_batch_test.go",
                new_line: 5
            }
        }')" > /dev/null

pass "Manual user discussion added on line 5"

# Verify we have 4 discussions now (3 old + 1 user)
COUNT_BEFORE=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq '[.[] | select(.notes[0].position != null)] | length')
info "Discussions before second run: $COUNT_BEFORE"

# Step 3: Run with DIFFERENT errors (should create 2 new + DELETE 3 old)
info "Step 3: Running with 2 new errors (old 3 should be DELETED, user comment NOT)..."
echo -e 'single_batch_test.go:3:1: missing doc\nsingle_batch_test.go:7:1: missing return' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=batch-test -f=golint

# Check results (filter only code comments with position)
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq '[.[] | select(.notes[0].position != null)]')

TOTAL_COUNT=$(echo "$DISCUSSIONS" | jq 'length')
info "Total discussions after delete: $TOTAL_COUNT"

# After delete: should have 2 new + 1 user = 3 discussions total
# (the 3 old "unused" comments should be deleted)
if [ "$TOTAL_COUNT" -ne 3 ]; then
    fail "Expected 3 discussions (2 new + 1 user), got $TOTAL_COUNT"
fi
pass "Correct count after delete: 3 discussions"

# Verify old comments are DELETED (not present)
OLD_COMMENTS=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].body | contains("unused old"))] | length')
if [ "$OLD_COMMENTS" -eq 0 ]; then
    pass "All 3 old comments were DELETED"
else
    fail "Old comments should be deleted, but found $OLD_COMMENTS"
fi

# Verify new comments exist
NEW_COMMENTS=$(echo "$DISCUSSIONS" | jq '[.[] | select((.notes[0].body | contains("missing doc")) or (.notes[0].body | contains("missing return")))] | length')
if [ "$NEW_COMMENTS" -eq 2 ]; then
    pass "2 new comments were created"
else
    fail "Expected 2 new comments, got $NEW_COMMENTS"
fi

# Verify user comment was NOT deleted
USER_COMMENT=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].body | contains("manual user comment"))] | length')
if [ "$USER_COMMENT" -eq 1 ]; then
    pass "User manual comment was NOT deleted (correct!)"
else
    fail "User manual comment was incorrectly deleted"
fi

# Note about no notifications
echo ""
info "NOTE: DELETE operation does NOT send email notifications"
info "Old comments are completely removed from the MR"
info "User manual comment was preserved and NOT touched by reviewdog"

echo ""
echo "=== Test 13 Complete ==="
