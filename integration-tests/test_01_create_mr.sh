#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Test 01: Create Merge Request ==="

# Delete existing branch if exists
info "Cleaning up existing test branch..."
curl -s -X DELETE "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/branches/feature-integration-test" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" > /dev/null 2>&1 || true

# Create new branch
info "Creating feature branch..."
BRANCH_RESULT=$(curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/branches" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "branch": "feature-integration-test",
        "ref": "main"
    }')

BRANCH_NAME=$(echo "$BRANCH_RESULT" | jq -r '.name // empty')
if [ -z "$BRANCH_NAME" ]; then
    fail "Failed to create branch: $BRANCH_RESULT"
fi
pass "Branch created: $BRANCH_NAME"

# Create test file with issues
info "Creating test file with lint issues..."
FILE_CONTENT='package main

import "fmt"

func main() {
    x := 1
    y := 2
    z := 3
    fmt.Println(x + y)
    // z is unused - lint error
}
'

curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/files/integration_test.go" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg content "$FILE_CONTENT" '{
        branch: "feature-integration-test",
        content: $content,
        commit_message: "Add integration_test.go with lint issues"
    }')" > /dev/null

pass "Test file created"

# Close existing MR if any
info "Closing existing MRs..."
EXISTING_MRS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests?state=opened&source_branch=feature-integration-test" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

echo "$EXISTING_MRS" | jq -r '.[].iid' | while read MR_IID; do
    if [ -n "$MR_IID" ]; then
        curl -s -X PUT "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID" \
            -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"state_event": "close"}' > /dev/null
    fi
done

# Create MR
info "Creating Merge Request..."
MR_RESULT=$(curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "source_branch": "feature-integration-test",
        "target_branch": "main",
        "title": "Integration Test MR"
    }')

MR_IID=$(echo "$MR_RESULT" | jq -r '.iid // empty')
MR_SHA=$(echo "$MR_RESULT" | jq -r '.sha // empty')

if [ -z "$MR_IID" ]; then
    fail "Failed to create MR: $MR_RESULT"
fi

pass "MR created: IID=$MR_IID, SHA=$MR_SHA"

# Save MR info for other tests
echo "export CI_PULL_REQUEST=$MR_IID" > "$SCRIPT_DIR/.mr_info"
echo "export CI_COMMIT=$MR_SHA" >> "$SCRIPT_DIR/.mr_info"

echo ""
echo "=== Test 01 Complete ==="
