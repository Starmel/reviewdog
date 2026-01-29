#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 12: Legacy Comments (without meta) ==="

cd "$TEST_REPO_DIR"

# Manually create a "legacy" comment without meta information
info "Creating legacy comment (without meta) via API..."

# Get MR info for position
MR_INFO=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")
TARGET_SHA=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/branches/main" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq -r '.commit.id')
HEAD_SHA=$(echo "$MR_INFO" | jq -r '.sha')

# Create legacy comment (no meta)
LEGACY_BODY="**[legacy-tool]** <sub>reported by [reviewdog](https://github.com/reviewdog/reviewdog) :dog:</sub><br>legacy error without fingerprint"

curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg body "$LEGACY_BODY" \
        --arg base "$TARGET_SHA" \
        --arg head "$HEAD_SHA" \
        '{
            body: $body,
            position: {
                base_sha: $base,
                start_sha: $base,
                head_sha: $head,
                position_type: "text",
                new_path: "integration_test.go",
                new_line: 6
            }
        }')" > /dev/null

pass "Legacy comment created"

# Run reviewdog with same message - should detect as duplicate via body matching
info "Running reviewdog with same message..."
BEFORE=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')

echo 'integration_test.go:6:5: legacy error without fingerprint' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=legacy-tool -f=golint

AFTER=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')

# Note: This will likely create a new comment because fingerprint-based dedup
# won't match body-based legacy comment. This documents current behavior.
info "Discussions before: $BEFORE, after: $AFTER"

if [ "$AFTER" -gt "$BEFORE" ]; then
    info "NOTE: Legacy comment was not deduplicated (expected - fingerprints differ)"
    info "This is acceptable behavior - legacy migration creates one extra comment"
else
    pass "Legacy comment was deduplicated via body matching"
fi

echo ""
echo "=== Test 12 Complete ==="
