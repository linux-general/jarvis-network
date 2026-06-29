#!/usr/bin/env bash
# infra-status.sh — report uncommitted changes across infra repos.
#
# Runs alongside snapshot-state.sh. Lists each tracked infra repo and any
# uncommitted / unpushed work. We deliberately do NOT auto-commit because:
#   1. Joe has accidentally pasted secrets into files before (chat-history
#      credentials); a blind auto-commit would publish them.
#   2. Half-done work (mid-edit, broken state) would land in main.
#
# Instead, the script writes a status report to stdout + to a sidecar file
# in $HOME/.config/jarvis/infra-status.txt and uploads it alongside the
# snapshot. Operators get a nudge that there's pending work; they decide
# whether to commit.
#
# Output is suitable for cron (silent on clean, noisy on pending).

set -euo pipefail

# Repos to check. Override with INFRA_REPOS="path1 path2 ..." for non-default
# layouts (e.g. when ${HOME}/c3po-ready isn't where the code lives).
if [ -n "${INFRA_REPOS:-}" ]; then
  # shellcheck disable=SC2206
  REPOS=($INFRA_REPOS)
else
  REPOS=(
    "$HOME/jarvis-network"
    "$HOME/c3po-ready"
    "$HOME/jarvis-headscale"
    "${LLM_WIKI_ROOT:-$HOME/llm-wiki}"
  )
fi

REPORT="$HOME/.config/jarvis/infra-status.txt"
mkdir -p "$(dirname "$REPORT")"

{
  echo "# infra status @ $(date -Iseconds)"
  echo "# host: $(hostname -s)"
  echo
  any_dirty=0
  for repo in "${REPOS[@]}"; do
    if [ ! -d "$repo/.git" ]; then
      echo "## $(basename "$repo")  (not a git repo)"
      echo "  skipped"
      continue
    fi
    cd "$repo"
    short=$(basename "$repo")
    echo "## $short ($(git -C . config --get remote.origin.url 2>/dev/null || echo 'no remote'))"

    # Uncommitted changes
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      any_dirty=1
      echo "  ⚠ uncommitted changes:"
      git status --porcelain | sed 's/^/    /'
    else
      echo "  ✓ working tree clean"
    fi

    # Local commits ahead of remote
    local_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -n "$local_branch" ]; then
      ahead=$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo "0")
      if [ "$ahead" -gt 0 ] 2>/dev/null; then
        any_dirty=1
        echo "  ⚠ $ahead unpushed commit(s) on $local_branch:"
        git log --oneline "@{u}..HEAD" 2>/dev/null | sed 's/^/    /'
      fi
    fi
    echo
  done
  echo "summary: $([ $any_dirty -eq 0 ] && echo 'all clean' || echo 'PENDING WORK — review and commit')"
} | tee "$REPORT"

exit 0
