#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  reviewdog GitLab Integration Tests"
echo "========================================"
echo ""

# Build reviewdog
info "Building reviewdog..."
cd "$SCRIPT_DIR/.."
go build -o reviewdog ./cmd/reviewdog/
cd "$SCRIPT_DIR"
pass "reviewdog built"

# Check GitLab is running
info "Checking GitLab status..."
if ! docker ps --format '{{.Names}}' | grep -q "^gitlab$"; then
    echo ""
    echo "GitLab is not running. Run setup.sh first:"
    echo "  ./setup.sh"
    exit 1
fi
pass "GitLab is running"

# Run all tests
TESTS=(
    "test_01_create_mr.sh"
    "test_02_post_comment.sh"
    "test_03_deduplication.sh"
    "test_04_resolve_outdated.sh"
    "test_05_multiple_tools.sh"
    "test_06_suggestions.sh"
    "test_07_empty_toolname.sh"
    "test_08_discussion_with_replies.sh"
    "test_09_same_line_different_message.sh"
    "test_10_large_batch.sh"
    "test_11_api_error_handling.sh"
    "test_12_legacy_comments.sh"
)

PASSED=0
FAILED=0

for test in "${TESTS[@]}"; do
    echo ""
    echo "----------------------------------------"
    if bash "$SCRIPT_DIR/$test"; then
        ((PASSED++))
    else
        ((FAILED++))
        echo -e "${RED}Test failed: $test${NC}"
    fi
done

echo ""
echo "========================================"
echo "  Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
