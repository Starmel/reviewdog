#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== GitLab Integration Test Setup ==="

# Check if GitLab container exists
if docker ps -a --format '{{.Names}}' | grep -q "^gitlab$"; then
    if docker ps --format '{{.Names}}' | grep -q "^gitlab$"; then
        echo "GitLab container is already running"
    else
        echo "Starting existing GitLab container..."
        docker start gitlab
    fi
else
    echo "Creating new GitLab container..."
    docker run -d \
        --name gitlab \
        --hostname localhost \
        -p 8080:80 \
        -p 2222:22 \
        --shm-size 256m \
        gitlab/gitlab-ce:latest
fi

# Wait for GitLab to be healthy
echo "Waiting for GitLab to become healthy (this may take 2-5 minutes)..."
while [ "$(docker inspect --format='{{.State.Health.Status}}' gitlab 2>/dev/null)" != "healthy" ]; do
    echo -n "."
    sleep 10
done
echo ""
echo "GitLab is ready!"

# Get root password
ROOT_PASSWORD=$(docker exec gitlab grep 'Password:' /etc/gitlab/initial_root_password 2>/dev/null | awk '{print $2}')
echo "Root password: $ROOT_PASSWORD"

# Create access token
echo "Creating access token..."
docker exec gitlab gitlab-rails runner "
token = User.find_by_username('root').personal_access_tokens.find_by(name: 'reviewdog-test')
if token.nil?
  token = User.find_by_username('root').personal_access_tokens.create(
    name: 'reviewdog-test',
    scopes: [:api, :read_api, :read_repository, :write_repository],
    expires_at: 365.days.from_now
  )
  token.set_token('$GITLAB_TOKEN')
  token.save!
  puts 'Token created: $GITLAB_TOKEN'
else
  puts 'Token already exists'
end
"

# Create test project if not exists
echo "Creating test project..."
PROJECT_EXISTS=$(curl -s "$GITLAB_URL/api/v4/projects?search=test-reviewdog" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" | jq 'length')

if [ "$PROJECT_EXISTS" == "0" ]; then
    curl -s -X POST "$GITLAB_URL/api/v4/projects" \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "test-reviewdog",
            "initialize_with_readme": true
        }' | jq -r '.path_with_namespace'
    echo "Project created"
else
    echo "Project already exists"
fi

echo ""
echo "=== Setup Complete ==="
echo "GitLab URL: $GITLAB_URL"
echo "Token: $GITLAB_TOKEN"
