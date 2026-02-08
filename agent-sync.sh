#!/bin/bash
# agent-sync - File semaphore-based sync from podman containers to GitHub PRs
#
# WARNING: This tool executes content produced by AI agents. It applies patches
# and runs commit messages authored inside containers with minimal validation.
# Use only with trusted AI agents in sandboxed environments. A malicious or
# prompt-injected agent could craft patches that introduce backdoors, secrets
# exfiltration, or other malicious code into your repositories. Always review
# PRs before merging. Never run this against production branches without review.
#
# Watches a container for a .ready semaphore file, then:
# 1. Copies the patch out of the container
# 2. Applies it to a local repo clone
# 3. Commits, pushes, and creates a PR via gh
#
# Usage:
#   agent-sync <container_id> [options]
#
# Options:
#   --repos-base <dir>    Base directory for repos (default: ~/dev/claude/owl)
#   --poll <seconds>      Poll interval (default: 10)
#   --semaphore <path>    Semaphore path inside container (default: /home/agent/workspace/.ready)
#   --once                Run once and exit (don't loop)
#   --dry-run             Show what would happen without executing
#
# Semaphore format (.ready file):
#   REPO=<repo-name>
#   PATCH=<path-to-patch-inside-container>
#   BRANCH=<branch-prefix>
#   MESSAGE=<commit-message>

set -euo pipefail

# Defaults
REPOS_BASE="${HOME}/dev/claude/owl"
POLL_INTERVAL=10
SEMAPHORE="/home/agent/workspace/.ready"
ONCE=false
DRY_RUN=false
CONTAINER=""

usage() {
  echo "Usage: agent-sync <container_id> [options]"
  echo ""
  echo "Options:"
  echo "  --repos-base <dir>    Base directory for repos (default: ~/dev/claude/owl)"
  echo "  --poll <seconds>      Poll interval (default: 10)"
  echo "  --semaphore <path>    Semaphore path in container (default: /home/agent/workspace/.ready)"
  echo "  --once                Run once and exit"
  echo "  --dry-run             Show what would happen"
  echo "  -h, --help            Show this help"
  exit 0
}

log() {
  echo "[agent-sync] $(date '+%H:%M:%S') $*"
}

err() {
  echo "[agent-sync] $(date '+%H:%M:%S') ERROR: $*" >&2
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --repos-base) REPOS_BASE="$2"; shift 2 ;;
    --poll) POLL_INTERVAL="$2"; shift 2 ;;
    --semaphore) SEMAPHORE="$2"; shift 2 ;;
    --once) ONCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    -*) err "Unknown option: $1"; exit 1 ;;
    *)
      if [ -z "$CONTAINER" ]; then
        CONTAINER="$1"
      else
        err "Unexpected argument: $1"; exit 1
      fi
      shift ;;
  esac
done

if [ -z "$CONTAINER" ]; then
  err "Container ID required"
  usage
fi

# Verify container is running
if ! podman inspect "$CONTAINER" &>/dev/null; then
  err "Container $CONTAINER not found"
  exit 1
fi

# Verify gh is available
if ! command -v gh &>/dev/null; then
  err "gh CLI not found. Install: https://cli.github.com"
  exit 1
fi

log "WARNING: Only use with trusted AI agents. Review all PRs before merging."
log "Watching container $CONTAINER"
log "Semaphore: $SEMAPHORE"
log "Repos base: $REPOS_BASE"
log "Poll interval: ${POLL_INTERVAL}s"
[ "$DRY_RUN" = true ] && log "DRY RUN MODE"

process_semaphore() {
  # Read semaphore content
  local content
  content=$(podman exec "$CONTAINER" cat "$SEMAPHORE" 2>/dev/null) || {
    err "Failed to read semaphore"
    return 1
  }

  # Parse fields
  local repo patch branch message
  repo=$(echo "$content" | grep '^REPO=' | head -1 | cut -d= -f2-)
  patch=$(echo "$content" | grep '^PATCH=' | head -1 | cut -d= -f2-)
  branch=$(echo "$content" | grep '^BRANCH=' | head -1 | cut -d= -f2-)
  message=$(echo "$content" | grep '^MESSAGE=' | head -1 | cut -d= -f2-)

  # Validate
  if [ -z "$repo" ] || [ -z "$patch" ] || [ -z "$branch" ] || [ -z "$message" ]; then
    err "Semaphore missing required fields (need REPO, PATCH, BRANCH, MESSAGE)"
    err "Content: $content"
    podman exec "$CONTAINER" rm -f "$SEMAPHORE"
    return 1
  fi

  local repo_dir="$REPOS_BASE/$repo"
  local full_branch="${branch}-$(date +%s)"
  local local_patch="/tmp/agent-sync-${repo}-$$.patch"

  log "Repo: $repo"
  log "Branch: $full_branch"
  log "Message: $message"
  log "Patch source: $patch"

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] Would copy $patch from container"
    log "[dry-run] Would apply to $repo_dir on branch $full_branch"
    log "[dry-run] Would commit with message: $message"
    log "[dry-run] Would push and create PR"
    podman exec "$CONTAINER" rm -f "$SEMAPHORE"
    return 0
  fi

  # Copy patch out
  podman cp "$CONTAINER:$patch" "$local_patch" || {
    err "Failed to copy patch from container"
    return 1
  }

  # Remove semaphore (so we don't re-process)
  podman exec "$CONTAINER" rm -f "$SEMAPHORE"

  # Verify repo exists
  if [ ! -d "$repo_dir/.git" ]; then
    err "Repo not found: $repo_dir"
    rm -f "$local_patch"
    return 1
  fi

  # Apply patch and create PR
  pushd "$repo_dir" > /dev/null

  git fetch origin 2>/dev/null

  # Try main, then master
  local base_branch="main"
  if ! git rev-parse origin/main &>/dev/null; then
    base_branch="master"
  fi

  git checkout -b "$full_branch" "origin/$base_branch" || {
    err "Failed to create branch from origin/$base_branch"
    popd > /dev/null
    rm -f "$local_patch"
    return 1
  }

  if git apply "$local_patch"; then
    log "Patch applied successfully"
    git add -A
    git commit -m "$message"
    git push origin "$full_branch"
    gh pr create \
      --title "$message" \
      --body "Automated PR from agent-sync.

Source: container \`$CONTAINER\`
Branch: \`$full_branch\`"
    log "PR created!"
  else
    err "git apply failed"
    git checkout "$base_branch" 2>/dev/null
    git branch -D "$full_branch" 2>/dev/null
    popd > /dev/null
    rm -f "$local_patch"
    return 1
  fi

  popd > /dev/null
  rm -f "$local_patch"
  log "Done processing $repo"
}

# Main loop
while true; do
  if podman exec "$CONTAINER" test -f "$SEMAPHORE" 2>/dev/null; then
    log "Semaphore detected!"
    process_semaphore || true
  fi

  if [ "$ONCE" = true ]; then
    break
  fi

  sleep "$POLL_INTERVAL"
done
