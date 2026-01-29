#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 11: API Error Handling ==="

cd "$TEST_REPO_DIR"

# Test with invalid MR number
info "Testing with invalid MR number..."
export CI_PULL_REQUEST=99999

set +e
OUTPUT=$(echo 'integration_test.go:6:5: test error' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=error-test -f=golint 2>&1)
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
    pass "Correctly failed with invalid MR (exit code: $EXIT_CODE)"
else
    fail "Should have failed with invalid MR"
fi

# Restore valid MR
source "$SCRIPT_DIR/.mr_info"

# Test with invalid token
info "Testing with invalid token..."
ORIGINAL_TOKEN="$REVIEWDOG_GITLAB_API_TOKEN"
export REVIEWDOG_GITLAB_API_TOKEN="invalid-token"

set +e
OUTPUT=$(echo 'integration_test.go:6:5: test error' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=error-test -f=golint 2>&1)
EXIT_CODE=$?
set -e

export REVIEWDOG_GITLAB_API_TOKEN="$ORIGINAL_TOKEN"

if [ $EXIT_CODE -ne 0 ]; then
    pass "Correctly failed with invalid token (exit code: $EXIT_CODE)"
else
    fail "Should have failed with invalid token"
fi

# Test with file not in diff
info "Testing comment on file not in diff..."
set +e
OUTPUT=$(echo 'nonexistent_file.go:6:5: error on non-diff file' | \
    "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -name=error-test -f=golint 2>&1)
EXIT_CODE=$?
set -e

# Should succeed but not post comment (filtered out)
if [ $EXIT_CODE -eq 0 ]; then
    pass "Gracefully handled file not in diff"
else
    fail "Should not fail for file not in diff"
fi

echo ""
echo "=== Test 11 Complete ==="
