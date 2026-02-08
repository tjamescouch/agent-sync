# agent-sync

File semaphore-based sync from podman containers to GitHub PRs.

Bridges the gap between sandboxed AI agent containers and GitHub — when an agent has changes ready, it writes a `.ready` semaphore file, and this script automatically creates a PR.

> **Security warning:** This tool applies code produced by AI agents directly to your repositories and creates PRs on your behalf. A compromised or prompt-injected agent could craft patches containing malicious code, backdoors, or secrets exfiltration. **Use only with trusted AI agents.** Always review generated PRs before merging. Run agents in sandboxed containers with minimal permissions. Never point this at repositories where unreviewed commits could reach production.

## How it works

```
┌─────────────────────┐         ┌─────────────────────┐
│  Agent Container    │         │  Host (Mac/Linux)    │
│                     │         │                      │
│  1. Make changes    │         │  agent-sync watches  │
│  2. git diff > .patch│  ───>  │  for .ready file     │
│  3. Write .ready    │ podman  │                      │
│                     │  cp     │  3. Copy patch out   │
│                     │         │  4. git apply        │
│                     │         │  5. git push         │
│                     │         │  6. gh pr create     │
└─────────────────────┘         └─────────────────────┘
```

## Install

```bash
curl -O https://raw.githubusercontent.com/tjamescouch/agent-sync/main/agent-sync.sh
chmod +x agent-sync.sh
```

## Usage

```bash
# Start watching a container
./agent-sync.sh <container_id>

# With options
./agent-sync.sh abc123 --repos-base ~/projects --poll 5

# One-shot (check once and exit)
./agent-sync.sh abc123 --once

# Dry run
./agent-sync.sh abc123 --dry-run
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--repos-base <dir>` | `~/dev/claude/owl` | Base directory containing repo clones |
| `--poll <seconds>` | `10` | Poll interval |
| `--semaphore <path>` | `/home/agent/workspace/.ready` | Semaphore path inside container |
| `--once` | | Run once and exit |
| `--dry-run` | | Show what would happen |

## Semaphore format

The agent writes a `.ready` file with these fields:

```
REPO=agentchat-dashboard
PATCH=/home/agent/workspace/my-changes.patch
BRANCH=feature-name
MESSAGE=feat: description of changes
```

| Field | Description |
|-------|-------------|
| `REPO` | Repository directory name (under repos-base) |
| `PATCH` | Path to the git patch file inside the container |
| `BRANCH` | Branch name prefix (timestamp is appended) |
| `MESSAGE` | Commit message and PR title |

## Agent side

From inside the container, the agent workflow is:

```bash
# 1. Make changes to the cloned repo
cd /home/agent/workspace/some-repo
# ... edit files ...

# 2. Generate a patch
git diff > /home/agent/workspace/changes.patch

# 3. Signal readiness
cat > /home/agent/workspace/.ready << 'EOF'
REPO=some-repo
PATCH=/home/agent/workspace/changes.patch
BRANCH=my-feature
MESSAGE=feat: what I changed
EOF
```

agent-sync picks it up, creates the PR, and removes the semaphore.

## Requirements

- [podman](https://podman.io/)
- [gh](https://cli.github.com/) (authenticated)
- git
- Local clones of target repos under `--repos-base`

## Tests

```bash
# Basic tests (no container needed)
./agent-sync.test.sh

# Full tests with a live container
./agent-sync.test.sh <container_id>
```

## License

MIT
