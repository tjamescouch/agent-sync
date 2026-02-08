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
# Watches containers for a .ready semaphore file, then:
# 1. Copies the patch out of the container
# 2. Applies it to a local repo clone
# 3. Commits, pushes, and creates a PR via gh
#
# Usage:
#   agent-sync startsync [options]         Auto-discover and watch all agent containers
#   agent-sync <container_id> [options]    Watch a single container
#
# Options:
#   --repos-base <dir>    Base directory for repos (default: ~/dev/claude/owl)
#   --poll <seconds>      Poll interval (default: 10)
#   --semaphore <path>    Semaphore path inside container (default: /home/agent/workspace/.ready)
#   --image <name>        Image filter for startsync (default: agentchat-agent)
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
IMAGE_FILTER="agentchat-agent"
ONCE=false
DRY_RUN=false
CONTAINER=""
MODE="single"

# Track child PIDs for cleanup
CHILD_PIDS=()

usage() {
  echo "Usage:"
  echo "  agent-sync startsync [options]         Auto-discover all agent containers"
  echo "  agent-sync <container_id> [options]    Watch a single container"
  echo ""
  echo "Options:"
  echo "  --repos-base <dir>    Base directory for repos (default: ~/dev/claude/owl)"
  echo "  --poll <seconds>      Poll interval (default: 10)"
  echo "  --semaphore <path>    Semaphore path in container (default: /home/agent/workspace/.ready)"
  echo "  --image <name>        Image filter for startsync (default: agentchat-agent)"
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

cleanup_children() {
  if [ ${#CHILD_PIDS[@]} -gt 0 ]; then
    for pid in "${CHILD_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
  fi
  wait 2>/dev/null
  log "All watchers stopped."
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    startsync) MODE="startsync"; shift ;;
    --repos-base) REPOS_BASE="$2"; shift 2 ;;
    --poll) POLL_INTERVAL="$2"; shift 2 ;;
    --semaphore) SEMAPHORE="$2"; shift 2 ;;
    --image) IMAGE_FILTER="$2"; shift 2 ;;
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

if [ "$MODE" = "single" ] && [ -z "$CONTAINER" ]; then
  err "Container ID required (or use 'startsync' to auto-discover)"
  usage
fi

# Verify gh is available
if ! command -v gh &>/dev/null; then
  err "gh CLI not found. Install: https://cli.github.com"
  exit 1
fi

# Verify podman is available
if ! command -v podman &>/dev/null; then
  err "podman not found. Install: https://podman.io"
  exit 1
fi

log "WARNING: Only use with trusted AI agents. Review all PRs before merging."

process_semaphore() {
  local container="$1"
  local container_name
  container_name=$(podman inspect "$container" --format '{{.Name}}' 2>/dev/null || echo "$container")

  # Read semaphore content
  local content
  content=$(podman exec "$container" cat "$SEMAPHORE" 2>/dev/null) || {
    err "[$container_name] Failed to read semaphore"
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
    err "[$container_name] Semaphore missing required fields (need REPO, PATCH, BRANCH, MESSAGE)"
    err "[$container_name] Content: $content"
    podman exec "$container" rm -f "$SEMAPHORE"
    return 1
  fi

  local repo_dir="$REPOS_BASE/$repo"
  local full_branch="${branch}-$(date +%s)"
  local local_patch="/tmp/agent-sync-${repo}-$$.patch"

  log "[$container_name] Repo: $repo"
  log "[$container_name] Branch: $full_branch"
  log "[$container_name] Message: $message"

  if [ "$DRY_RUN" = true ]; then
    log "[$container_name] [dry-run] Would copy $patch from container"
    log "[$container_name] [dry-run] Would apply to $repo_dir on branch $full_branch"
    log "[$container_name] [dry-run] Would commit with message: $message"
    log "[$container_name] [dry-run] Would push and create PR"
    podman exec "$container" rm -f "$SEMAPHORE"
    return 0
  fi

  # Copy patch out
  podman cp "$container:$patch" "$local_patch" || {
    err "[$container_name] Failed to copy patch from container"
    return 1
  }

  # Remove semaphore (so we don't re-process)
  podman exec "$container" rm -f "$SEMAPHORE"

  # Verify repo exists
  if [ ! -d "$repo_dir/.git" ]; then
    err "[$container_name] Repo not found: $repo_dir"
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
    err "[$container_name] Failed to create branch from origin/$base_branch"
    popd > /dev/null
    rm -f "$local_patch"
    return 1
  }

  if git apply "$local_patch"; then
    log "[$container_name] Patch applied successfully"
    git add -A
    git commit -m "$message"
    git push origin "$full_branch"
    gh pr create \
      --title "$message" \
      --body "Automated PR from agent-sync.

Source: container \`$container_name\`
Branch: \`$full_branch\`"
    log "[$container_name] PR created!"
  else
    err "[$container_name] git apply failed"
    git checkout "$base_branch" 2>/dev/null
    git branch -D "$full_branch" 2>/dev/null
    popd > /dev/null
    rm -f "$local_patch"
    return 1
  fi

  popd > /dev/null
  rm -f "$local_patch"
  log "[$container_name] Done processing $repo"
}

watch_container() {
  local container="$1"
  local container_name
  container_name=$(podman inspect "$container" --format '{{.Name}}' 2>/dev/null || echo "$container")

  log "[$container_name] Watching (semaphore: $SEMAPHORE)"

  while true; do
    # Check container is still running
    if ! podman inspect "$container" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
      log "[$container_name] Container stopped, exiting watcher"
      return 0
    fi

    if podman exec "$container" test -f "$SEMAPHORE" 2>/dev/null; then
      log "[$container_name] Semaphore detected!"
      process_semaphore "$container" || true
    fi

    if [ "$ONCE" = true ]; then
      return 0
    fi

    sleep "$POLL_INTERVAL"
  done
}

# --- startsync mode: auto-discover and watch all agent containers ---
if [ "$MODE" = "startsync" ]; then
  log "Discovering agent containers (image filter: *${IMAGE_FILTER}*)..."

  containers=$(podman ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}' | grep "$IMAGE_FILTER" || true)

  if [ -z "$containers" ]; then
    err "No running containers matching *${IMAGE_FILTER}* found"
    exit 1
  fi

  count=$(echo "$containers" | wc -l | tr -d ' ')
  log "Found $count agent container(s):"
  echo "$containers" | while IFS=$'\t' read -r id name image; do
    log "  $name ($id) — $image"
  done

  log "Semaphore: $SEMAPHORE"
  log "Repos base: $REPOS_BASE"
  log "Poll interval: ${POLL_INTERVAL}s"
  [ "$DRY_RUN" = true ] && log "DRY RUN MODE"

  trap cleanup_children EXIT INT TERM

  # Launch a watcher per container (use here-string to stay in current shell)
  while IFS=$'\t' read -r id name image; do
    watch_container "$id" &
    CHILD_PIDS+=($!)
  done <<< "$containers"

  # Wait for all watchers (or until interrupted)
  wait
  exit 0
fi

# --- single container mode (original behavior) ---
if ! podman inspect "$CONTAINER" &>/dev/null; then
  err "Container $CONTAINER not found"
  exit 1
fi

log "Watching container $CONTAINER"
log "Semaphore: $SEMAPHORE"
log "Repos base: $REPOS_BASE"
log "Poll interval: ${POLL_INTERVAL}s"
[ "$DRY_RUN" = true ] && log "DRY RUN MODE"

watch_container "$CONTAINER"
