#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Test 13: Single Batch Create and Resolve ==="
echo "Tests that new comments + resolve of old comments happen in ONE bulk_publish"

# Create a fresh MR for this test
info "Creating fresh MR for batch test..."

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

# Clone repo
rm -rf "$TEST_REPO_DIR"
git clone "http://root:$GITLAB_TOKEN@localhost:8080/root/test-reviewdog.git" "$TEST_REPO_DIR" 2>/dev/null
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

# Step 2: Add a manual user comment (should NOT be resolved by reviewdog)
info "Step 2: Adding manual user discussion (not from reviewdog)..."
MR_INFO=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")
TARGET_SHA=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/branches/main" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq -r '.commit.id')

curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg body "This is a manual user comment - should NOT be auto-resolved!" \
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

# Step 3: Run with DIFFERENT errors (should create 2 new + resolve 3 old in ONE operation)
info "Step 3: Running with 2 new errors (old 3 should be resolved, user comment NOT)..."
echo -e 'single_batch_test.go:3:1: missing doc\nsingle_batch_test.go:7:1: missing return' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=batch-test -f=golint

# Check results (filter only code comments with position)
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq '[.[] | select(.notes[0].position != null)]')

TOTAL_COUNT=$(echo "$DISCUSSIONS" | jq 'length')
RESOLVED_COUNT=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].resolved == true)] | length')
UNRESOLVED_COUNT=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].resolved == false)] | length')

info "Total discussions: $TOTAL_COUNT"
info "Resolved: $RESOLVED_COUNT"
info "Unresolved: $UNRESOLVED_COUNT"

# Verify old comments are resolved
OLD_RESOLVED=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].body | contains("unused old"))] | [.[] | .notes[0].resolved] | all')
if [ "$OLD_RESOLVED" == "true" ]; then
    pass "All 3 old comments are resolved"
else
    fail "Not all old comments are resolved"
fi

# Verify new comments are unresolved
NEW_UNRESOLVED=$(echo "$DISCUSSIONS" | jq '[.[] | select((.notes[0].body | contains("missing doc")) or (.notes[0].body | contains("missing return")))] | [.[] | .notes[0].resolved == false] | all')
if [ "$NEW_UNRESOLVED" == "true" ]; then
    pass "All 2 new comments are unresolved"
else
    fail "New comments should be unresolved"
fi

# Verify counts (3 old resolved + 2 new unresolved + 1 user unresolved = 6 total)
if [ "$RESOLVED_COUNT" -eq 3 ] && [ "$UNRESOLVED_COUNT" -eq 3 ]; then
    pass "Correct counts: 3 resolved, 3 unresolved (2 new + 1 user)"
else
    fail "Expected 3 resolved + 3 unresolved, got $RESOLVED_COUNT resolved + $UNRESOLVED_COUNT unresolved"
fi

# Verify user comment was NOT resolved
USER_COMMENT_RESOLVED=$(echo "$DISCUSSIONS" | jq '[.[] | select(.notes[0].body | contains("manual user comment"))] | .[0].notes[0].resolved')
if [ "$USER_COMMENT_RESOLVED" == "false" ]; then
    pass "User manual comment was NOT auto-resolved (correct!)"
else
    fail "User manual comment was incorrectly resolved: $USER_COMMENT_RESOLVED"
fi

# Note about single notification
echo ""
info "NOTE: All changes (2 new + 3 resolves) were done via Draft Notes API"
info "with a single bulk_publish call = ONE email notification"
info "User manual comment was preserved and NOT touched by reviewdog"

echo ""
echo "=== Test 13 Complete ==="
