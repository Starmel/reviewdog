#!/bin/bash

# GitLab configuration
export GITLAB_URL="http://localhost:8080"
export GITLAB_API="$GITLAB_URL/api/v4"
export GITLAB_TOKEN="glpat-reviewdog-test-token123"
export REVIEWDOG_GITLAB_API_TOKEN="$GITLAB_TOKEN"

# Project configuration
export CI_REPO_OWNER="root"
export CI_REPO_NAME="test-reviewdog"
export PROJECT_ID=1

# Paths
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REVIEWDOG_BIN="$SCRIPT_DIR/../reviewdog"
export TEST_REPO_DIR="/tmp/test-reviewdog-integration"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    exit 1
}

info() {
    echo -e "${YELLOW}→${NC} $1"
}
