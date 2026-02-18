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
WORMHOLE="${HOME}/dev/claude/wormhole"
POLL_INTERVAL=10
SEMAPHORE="/home/agent/workspace/.ready"
IMAGE_FILTER="agentchat-agent"
ONCE=false
DRY_RUN=false
CONTAINER=""
MODE="single"
PIDFILE="${HOME}/.agentchat/agent-sync.pid"
LOGFILE="${HOME}/.agentchat/agent-sync.log"
BACKGROUND=false
LIMA_INSTANCE=""  # When set, wrap all podman calls with: limactl shell <instance> --

# Track child PIDs for cleanup
CHILD_PIDS=()

usage() {
  echo "Usage:"
  echo "  agent-sync startsync [options]         Auto-discover all agent containers"
  echo "  agent-sync daemon [options]            Daemon mode: continuous discovery + extraction"
  echo "  agent-sync daemon stop                 Stop a running daemon"
  echo "  agent-sync daemon status               Show daemon status"
  echo "  agent-sync <container_id> [options]    Watch a single container"
  echo ""
  echo "Options:"
  echo "  --repos-base <dir>    Base directory for repos (default: ~/dev/claude/owl)"
  echo "  --poll <seconds>      Poll interval (default: 10)"
  echo "  --semaphore <path>    Semaphore path in container (default: /home/agent/workspace/.ready)"
  echo "  --image <name>        Image filter for startsync/daemon (default: agentchat-agent)"
  echo "  --pidfile <path>      PID file for daemon (default: ~/.agentchat/agent-sync.pid)"
  echo "  --logfile <path>      Log file for daemon (default: ~/.agentchat/agent-sync.log)"
  echo "  --background          Fork daemon to background"
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

DAEMON_SUBCMD=""

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    startsync) MODE="startsync"; shift ;;
    daemon)
      MODE="daemon"
      shift
      # Check for daemon subcommands (stop, status)
      if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
        DAEMON_SUBCMD="$1"; shift
      fi
      ;;
    --repos-base) REPOS_BASE="$2"; shift 2 ;;
    --poll) POLL_INTERVAL="$2"; shift 2 ;;
    --semaphore) SEMAPHORE="$2"; shift 2 ;;
    --image) IMAGE_FILTER="$2"; shift 2 ;;
    --pidfile) PIDFILE="$2"; shift 2 ;;
    --logfile) LOGFILE="$2"; shift 2 ;;
    --background) BACKGROUND=true; shift ;;
    --once) ONCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --lima) LIMA_INSTANCE="$2"; shift 2 ;;
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
  err "Container ID required (or use 'startsync'/'daemon' to auto-discover)"
  usage
fi

# Build podman command array (supports --lima for Lima VM containers)
if [ -n "$LIMA_INSTANCE" ]; then
  PODMAN=(limactl shell "$LIMA_INSTANCE" -- podman)
  log "Using Lima instance: $LIMA_INSTANCE"
else
  PODMAN=(podman)
fi

# Verify gh is available
if ! command -v gh &>/dev/null; then
  err "gh CLI not found. Install: https://cli.github.com"
  exit 1
fi

# Verify podman/limactl is available
if [ -n "$LIMA_INSTANCE" ]; then
  if ! command -v limactl &>/dev/null; then
    err "limactl not found. Install Lima: https://lima-vm.io"
    exit 1
  fi
elif ! command -v podman &>/dev/null; then
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
  content=$("${PODMAN[@]}" exec "$container" cat "$SEMAPHORE" 2>/dev/null) || {
    err "[$container_name] Failed to read semaphore"
    return 1
  }

  # Check for raw-copy mode (empty .ready = just copy files to wormhole)
  local trimmed
  trimmed=$(echo "$content" | tr -d '[:space:]')
  if [ -z "$trimmed" ]; then
    log "[$container_name] Empty semaphore — raw copy mode"
    local dest="$WORMHOLE/$container_name"
    mkdir -p "$dest"
    if [ "$DRY_RUN" = true ]; then
      log "[$container_name] [dry-run] Would copy workspace to $dest"
      "${PODMAN[@]}" exec "$container" rm -f "$SEMAPHORE"
      return 0
    fi
    local workspace_dir
    workspace_dir=$(dirname "$SEMAPHORE")
    "${PODMAN[@]}" cp "$container:$workspace_dir/." "$dest/" 2>/dev/null || {
      log "[$container_name] podman cp failed, falling back to tar"
      "${PODMAN[@]}" exec "$container" tar -cf - -C "$workspace_dir" . 2>/dev/null | tar -xf - -C "$dest/" || {
        err "[$container_name] Failed to copy workspace from container"
        return 1
      }
    }
    rm -f "$dest/.ready"
    "${PODMAN[@]}" exec "$container" rm -f "$SEMAPHORE"
    log "[$container_name] Files copied to $dest"
    return 0
  fi

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

  # Copy patch out (try podman cp first, fall back to exec cat for symlink issues)
  if ! "${PODMAN[@]}" cp "$container:$patch" "$local_patch" 2>/dev/null; then
    log "[$container_name] podman cp failed, falling back to exec cat"
    "${PODMAN[@]}" exec "$container" cat "$patch" > "$local_patch" 2>/dev/null || {
      err "[$container_name] Failed to copy patch from container"
      return 1
    }
  fi

  # Remove semaphore (so we don't re-process)
  "${PODMAN[@]}" exec "$container" rm -f "$SEMAPHORE"

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
  container_name=$("${PODMAN[@]}" inspect "$container" --format '{{.Name}}' 2>/dev/null || echo "$container")

  log "[$container_name] Watching (semaphore: $SEMAPHORE)"

  while true; do
    # Check container is still running
    if ! "${PODMAN[@]}" inspect "$container" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
      log "[$container_name] Container stopped, exiting watcher"
      return 0
    fi

    if "${PODMAN[@]}" exec "$container" test -f "$SEMAPHORE" 2>/dev/null; then
      log "[$container_name] Semaphore detected!"
      process_semaphore "$container" || true
    fi

    if [ "$ONCE" = true ]; then
      return 0
    fi

    sleep "$POLL_INTERVAL"
  done
}

# --- daemon mode: continuous discovery + extraction ---
daemon_cleanup() {
  rm -f "$PIDFILE"
  log "Daemon stopped."
}

daemon_stop() {
  if [ ! -f "$PIDFILE" ]; then
    echo "No daemon running (no PID file at $PIDFILE)"
    exit 1
  fi
  local pid
  pid=$(cat "$PIDFILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo "Stopping agent-sync daemon (PID $pid)..."
    kill "$pid"
    # Wait up to 10s for clean exit
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ $waited -lt 10 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "Daemon didn't stop cleanly, sending SIGKILL..."
      kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    echo "Daemon stopped."
  else
    echo "Stale PID file (process $pid not running). Cleaning up."
    rm -f "$PIDFILE"
  fi
  exit 0
}

daemon_status() {
  if [ ! -f "$PIDFILE" ]; then
    echo "No daemon running (no PID file at $PIDFILE)"
    exit 0
  fi
  local pid
  pid=$(cat "$PIDFILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo "agent-sync daemon running (PID $pid)"
    echo "PID file: $PIDFILE"
    echo "Log file: $LOGFILE"
    # Show recent extractions from log
    if [ -f "$LOGFILE" ]; then
      local extractions
      extractions=$(grep -c "Semaphore detected" "$LOGFILE" 2>/dev/null || echo "0")
      echo "Total extractions: $extractions"
      echo "Last 3 log lines:"
      tail -3 "$LOGFILE" | sed 's/^/  /'
    fi
  else
    echo "Stale PID file (process $pid not running). Cleaning up."
    rm -f "$PIDFILE"
  fi
  exit 0
}

daemon_sweep() {
  # Single sweep: discover all containers, check each for semaphores
  local containers
  containers=$(podman ps --format '{{.ID}}' --filter "label=agentchat.agent=true" 2>/dev/null || true)

  # Fallback to image name filter if no labeled containers found
  if [ -z "$containers" ]; then
    containers=$(podman ps --format '{{.ID}}\t{{.Image}}' 2>/dev/null | grep "$IMAGE_FILTER" | cut -f1 || true)
  fi

  if [ -z "$containers" ]; then
    return 0
  fi

  local count=0
  while IFS= read -r container_id; do
    [ -z "$container_id" ] && continue

    # Check container is still running
    if ! podman inspect "$container_id" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
      continue
    fi

    # Check for semaphore
    if podman exec "$container_id" test -f "$SEMAPHORE" 2>/dev/null; then
      local cname
      cname=$(podman inspect "$container_id" --format '{{.Name}}' 2>/dev/null || echo "$container_id")
      log "Semaphore detected in $cname!"
      process_semaphore "$container_id" || true
      count=$((count + 1))
    fi
  done <<< "$containers"

  if [ $count -gt 0 ]; then
    log "Sweep complete: extracted from $count container(s)"
  fi
}

daemon_run() {
  mkdir -p "$(dirname "$PIDFILE")"

  # Check for existing daemon (skip when launched via --background, parent handles PID)
  if [ "${_DAEMON_BG:-}" != "1" ]; then
    if [ -f "$PIDFILE" ]; then
      local existing_pid
      existing_pid=$(cat "$PIDFILE")
      if kill -0 "$existing_pid" 2>/dev/null; then
        err "Daemon already running (PID $existing_pid). Use 'daemon stop' first."
        exit 1
      else
        log "Removing stale PID file"
        rm -f "$PIDFILE"
      fi
    fi
    echo $$ > "$PIDFILE"
  fi
  trap daemon_cleanup EXIT INT TERM

  log "Daemon started (PID $$)"
  log "Image filter: *${IMAGE_FILTER}*"
  log "Semaphore: $SEMAPHORE"
  log "Repos base: $REPOS_BASE"
  log "Poll interval: ${POLL_INTERVAL}s"
  [ "$DRY_RUN" = true ] && log "DRY RUN MODE"

  # Main loop: sweep all containers every POLL_INTERVAL
  while true; do
    daemon_sweep
    sleep "$POLL_INTERVAL"
  done
}

if [ "$MODE" = "daemon" ]; then
  case "$DAEMON_SUBCMD" in
    stop) daemon_stop ;;
    status) daemon_status ;;
    "")
      if [ "$BACKGROUND" = true ]; then
        mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$PIDFILE")"
        # Check for existing daemon before forking
        if [ -f "$PIDFILE" ]; then
          existing_pid=$(cat "$PIDFILE")
          if kill -0 "$existing_pid" 2>/dev/null; then
            err "Daemon already running (PID $existing_pid). Use 'daemon stop' first."
            exit 1
          else
            log "Removing stale PID file"
            rm -f "$PIDFILE"
          fi
        fi
        log "Starting daemon in background (log: $LOGFILE)"
        _DAEMON_BG=1 daemon_run >> "$LOGFILE" 2>&1 &
        DAEMON_PID=$!
        echo "$DAEMON_PID" > "$PIDFILE"
        disown
        echo "Daemon started in background (PID $DAEMON_PID)"
        exit 0
      else
        daemon_run
      fi
      ;;
    *) err "Unknown daemon subcommand: $DAEMON_SUBCMD"; usage ;;
  esac
  exit 0
fi

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
