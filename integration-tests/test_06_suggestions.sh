#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/.mr_info"

echo "=== Test 06: Code Suggestions ==="

cd "$TEST_REPO_DIR"

# Create rdjson input with suggestion
RDJSON_INPUT=$(cat <<'EOF'
{
  "source": {
    "name": "suggestion-linter"
  },
  "diagnostics": [
    {
      "message": "Use fmt.Printf instead of fmt.Println for formatted output",
      "location": {
        "path": "integration_test.go",
        "range": {
          "start": { "line": 9, "column": 5 },
          "end": { "line": 9, "column": 30 }
        }
      },
      "suggestions": [
        {
          "text": "    fmt.Printf(\"%d\\n\", x + y)",
          "range": {
            "start": { "line": 9 },
            "end": { "line": 9 }
          }
        }
      ]
    }
  ]
}
EOF
)

info "Running reviewdog with code suggestion..."
echo "$RDJSON_INPUT" | "$REVIEWDOG_BIN" -reporter=gitlab-mr-discussion -f=rdjson

# Check if suggestion was created
DISCUSSIONS=$(curl -s "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$CI_PULL_REQUEST/discussions" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")

SUGGESTION_COMMENT=$(echo "$DISCUSSIONS" | jq -r '[.[] | select(.notes[0].body | contains("suggestion-linter"))] | .[-1].notes[0].body // empty')

if [ -n "$SUGGESTION_COMMENT" ]; then
    pass "Suggestion comment created"
else
    fail "Suggestion comment not found"
fi

if echo "$SUGGESTION_COMMENT" | grep -q '```suggestion'; then
    pass "Comment contains GitLab suggestion block"
else
    fail "Comment missing suggestion block"
fi

echo ""
echo "Comment preview:"
echo "$SUGGESTION_COMMENT" | head -20

echo ""
echo "=== Test 06 Complete ==="
