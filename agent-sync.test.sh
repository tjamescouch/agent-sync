#!/bin/bash
# agent-sync tests
# Requires: podman, git, a running container
# Run: ./agent-sync.test.sh <container_id>

set -euo pipefail

PASS=0
FAIL=0
CONTAINER="${1:-}"

log() { echo "  $*"; }
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== agent-sync tests ==="
echo ""

# Test 1: Script is executable and has shebang
echo "Test 1: Script structure"
if head -1 agent-sync.sh | grep -q '#!/bin/bash'; then
  pass "Has bash shebang"
else
  fail "Missing bash shebang"
fi

if [ -x agent-sync.sh ] || chmod +x agent-sync.sh; then
  pass "Is executable"
else
  fail "Cannot make executable"
fi

# Test 2: Help flag works
echo ""
echo "Test 2: Help output"
if ./agent-sync.sh --help 2>&1 | grep -q 'Usage:'; then
  pass "--help shows usage"
else
  fail "--help doesn't show usage"
fi

# Test 3: Fails without container ID
echo ""
echo "Test 3: Argument validation"
if ./agent-sync.sh 2>&1 | grep -q 'Container ID required'; then
  pass "Fails without container ID"
else
  fail "Should fail without container ID"
fi

# Test 4: Fails with invalid container
echo ""
echo "Test 4: Container validation"
if command -v podman &>/dev/null; then
  if ./agent-sync.sh nonexistent-container-xyz 2>&1 | grep -q 'not found'; then
    pass "Rejects invalid container"
  else
    fail "Should reject invalid container"
  fi
else
  log "SKIPPED (podman not available)"
fi

# Test 5: Semaphore format parsing (unit test via subshell)
echo ""
echo "Test 5: Semaphore parsing"
SAMPLE="REPO=my-repo
PATCH=/home/agent/workspace/test.patch
BRANCH=test-branch
MESSAGE=test commit message"

repo=$(echo "$SAMPLE" | grep '^REPO=' | head -1 | cut -d= -f2-)
patch=$(echo "$SAMPLE" | grep '^PATCH=' | head -1 | cut -d= -f2-)
branch=$(echo "$SAMPLE" | grep '^BRANCH=' | head -1 | cut -d= -f2-)
message=$(echo "$SAMPLE" | grep '^MESSAGE=' | head -1 | cut -d= -f2-)

[ "$repo" = "my-repo" ] && pass "Parses REPO" || fail "REPO parse: got '$repo'"
[ "$patch" = "/home/agent/workspace/test.patch" ] && pass "Parses PATCH" || fail "PATCH parse: got '$patch'"
[ "$branch" = "test-branch" ] && pass "Parses BRANCH" || fail "BRANCH parse: got '$branch'"
[ "$message" = "test commit message" ] && pass "Parses MESSAGE" || fail "MESSAGE parse: got '$message'"

# Test 6: Handles message with special characters
echo ""
echo "Test 6: Special character handling"
SPECIAL="REPO=repo
PATCH=/path
BRANCH=branch
MESSAGE=feat: add foo & bar (v2.0)"

special_msg=$(echo "$SPECIAL" | grep '^MESSAGE=' | head -1 | cut -d= -f2-)
[ "$special_msg" = "feat: add foo & bar (v2.0)" ] && pass "Handles special chars in MESSAGE" || fail "Special chars: got '$special_msg'"

# Test 7: Dry run mode (only if container provided)
if [ -n "$CONTAINER" ]; then
  echo ""
  echo "Test 7: Dry run with live container"

  # Write a test semaphore
  podman exec "$CONTAINER" sh -c 'cat > /home/agent/workspace/.ready-test << EOF
REPO=test-repo
PATCH=/home/agent/workspace/nonexistent.patch
BRANCH=test
MESSAGE=test message
EOF'

  if ./agent-sync.sh "$CONTAINER" --semaphore /home/agent/workspace/.ready-test --dry-run --once 2>&1 | grep -q 'dry-run'; then
    pass "Dry run mode works"
  else
    fail "Dry run mode failed"
  fi

  # Clean up
  podman exec "$CONTAINER" rm -f /home/agent/workspace/.ready-test 2>/dev/null
else
  echo ""
  echo "Test 7: SKIPPED (no container ID provided)"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
