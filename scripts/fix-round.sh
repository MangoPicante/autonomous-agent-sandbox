#!/usr/bin/env bash
# Count agent-round-N labels on a PR. If under the cap, allocate the next
# round and add the label. If at the cap, add needs-human and signal stop.
#
# Usage:
#   scripts/fix-round.sh <pr_number>
#
# Required environment:
#   GH_REPO          owner/repo
#   MAX_FIX_ROUNDS   integer cap (default 3)
#
# Writes to $GITHUB_OUTPUT (when set):
#   at_cap=true|false
#   next_round=N       only when at_cap=false
set -euo pipefail

PR="${1:?usage: fix-round.sh <pr_number>}"
: "${GH_REPO:?GH_REPO is required}"
MAX="${MAX_FIX_ROUNDS:-3}"

labels=$(gh pr view "$PR" --repo "$GH_REPO" --json labels -q '.labels[].name')
existing=0
for n in $(seq 1 "$MAX"); do
  if echo "$labels" | grep -qx "agent-round-$n"; then
    existing=$n
  fi
done

if [ "$existing" -ge "$MAX" ]; then
  gh pr edit "$PR" --repo "$GH_REPO" --add-label needs-human
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "at_cap=true" >> "$GITHUB_OUTPUT"
  fi
  echo "cap reached at round $existing; added needs-human"
  exit 0
fi

next=$((existing + 1))
gh pr edit "$PR" --repo "$GH_REPO" --add-label "agent-round-$next"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "at_cap=false" >> "$GITHUB_OUTPUT"
  echo "next_round=$next" >> "$GITHUB_OUTPUT"
fi
echo "allocated round $next"
