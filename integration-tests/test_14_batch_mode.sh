#!/bin/bash
# Test 14: Batch Mode via Web Endpoint
# This test verifies that batch mode creates comments via draft notes and publishes them all at once.
# Requires: REVIEWDOG_GITLAB_BATCH_MODE=true, REVIEWDOG_GITLAB_USERNAME, REVIEWDOG_GITLAB_PASSWORD
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow override of GITLAB_TOKEN before sourcing config
GITLAB_TOKEN_OVERRIDE="${GITLAB_TOKEN:-}"
source "$SCRIPT_DIR/config.sh"
if [ -n "$GITLAB_TOKEN_OVERRIDE" ]; then
    export GITLAB_TOKEN="$GITLAB_TOKEN_OVERRIDE"
    export REVIEWDOG_GITLAB_API_TOKEN="$GITLAB_TOKEN"
fi

echo "=== Test 14: Batch Mode via Web Endpoint ==="

# GitLab password for web login
GITLAB_PASSWORD="${GITLAB_PASSWORD:-ReviewDog123!}"
GITLAB_HOST="${GITLAB_HOST:-localhost:8080}"

# Get MR info from API
MR=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests?state=opened" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq '.[0]')
MR_IID=$(echo "$MR" | jq -r '.iid')
HEAD_SHA=$(echo "$MR" | jq -r '.sha')
SOURCE_BRANCH=$(echo "$MR" | jq -r '.source_branch')

if [ -z "$MR_IID" ] || [ "$MR_IID" == "null" ]; then
    echo "No open MR found. Please create one first."
    exit 1
fi

echo "MR IID: $MR_IID"
echo "HEAD SHA: $HEAD_SHA"

# Clone repo
REPO_DIR=$(mktemp -d)
git clone -q "http://root:$GITLAB_PASSWORD@${GITLAB_HOST}/root/test-reviewdog.git" "$REPO_DIR"
cd "$REPO_DIR"
git checkout -q "$SOURCE_BRANCH"

# Count existing discussions (only code-related)
INITIAL_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq '[.[] | select(.notes[0].position != null)] | length')
echo "Initial discussion count: $INITIAL_COUNT"

# Get list of files in MR
MR_FILES=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/changes" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq -r '.changes[0].new_path')
echo "MR contains file: $MR_FILES"

# Create linter output with unique timestamps to avoid deduplication
TIMESTAMP=$(date +%s)
cat > /tmp/lint_output_batch.txt << EOF
${MR_FILES}:3:1: error: batch test error $TIMESTAMP on line 3 (test-batch)
${MR_FILES}:5:1: warning: batch test warning $TIMESTAMP on line 5 (test-batch)
${MR_FILES}:7:1: info: batch test info $TIMESTAMP on line 7 (test-batch)
EOF

# Setup environment
export REVIEWDOG_GITLAB_API_TOKEN="$GITLAB_TOKEN"
export GITLAB_API="$GITLAB_URL/api/v4"
export CI_MERGE_REQUEST_IID="$MR_IID"
export CI_PROJECT_PATH="root/test-reviewdog"
export CI_COMMIT_SHA="$HEAD_SHA"
export CI_REPO_OWNER="root"
export CI_REPO_NAME="test-reviewdog"
export CI_PULL_REQUEST="$MR_IID"

# Enable batch mode
export REVIEWDOG_GITLAB_BATCH_MODE="true"
export REVIEWDOG_GITLAB_USERNAME="root"
export REVIEWDOG_GITLAB_PASSWORD="$GITLAB_PASSWORD"

echo ""
echo "=== Running reviewdog with batch mode ==="
cat /tmp/lint_output_batch.txt | "$REVIEWDOG_BIN" \
    -f=golint \
    -name=test-batch \
    -reporter=gitlab-mr-discussion \
    -filter-mode=nofilter \
    -log-level=info 2>&1 || true

# Check results
echo ""
echo "=== Checking results ==="
sleep 1  # Give GitLab time to process

FINAL_COUNT=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq '[.[] | select(.notes[0].position != null)] | length')
echo "Final discussion count: $FINAL_COUNT"

NEW_COMMENTS=$((FINAL_COUNT - INITIAL_COUNT))
echo "New comments created: $NEW_COMMENTS"

# Show the new comments
echo ""
echo "=== New comments details ==="
curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq "[.[] | select(.notes[0].position != null)][-${NEW_COMMENTS}:] | .[] | {body: .notes[0].body[:50], new_line: .notes[0].position.new_line, file: .notes[0].position.new_path}"

# Verify
if [ "$NEW_COMMENTS" -ge 3 ]; then
    echo ""
    echo "=== SUCCESS: Batch mode created $NEW_COMMENTS comments with positions ==="
else
    echo ""
    echo "=== FAILURE: Expected 3 new comments, got $NEW_COMMENTS ==="
    exit 1
fi

# Cleanup
cd /
rm -rf "$REPO_DIR"
rm -f /tmp/lint_output_batch.txt

echo ""
echo "=== Test 14 PASSED ==="
