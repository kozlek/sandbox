#!/usr/bin/env bash
#
# Scenario: the activity log records a backport only when one happened
# (MRGFY-8674 / MRGFY-9158, engine #40255 / #40257).
#
#   run.sh           merge a PR into `bp/trunk`, then ask Mergify to backport it
#                    to `bp/stable` (exists) and `bp/legacy` (does not)
#   run.sh --reset   close every PR of the scenario and delete its branches
#
# Everything happens on throwaway branches, never `main`: `bp/trunk` stands in
# for the default branch, so the merge needs no queue and no CI, and the demo
# starts at the part worth watching.
#
# Requires git + gh (authenticated as kozlek). See README.md for the walkthrough.

set -euo pipefail

REPO="kozlek/sandbox"
TRUNK="bp/trunk"
STABLE="bp/stable"
MISSING="bp/legacy"
HEAD="bp/feature"

cd "$(dirname "$0")/../.."

require_clean_tree() {
  # The script commits on scratch branches; a modified tracked file would ride
  # along into them.
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "The working tree has uncommitted changes. Commit or stash them first." >&2
    exit 1
  fi
}

teardown() {
  echo "Closing scenario PRs and deleting branches..."
  for base in "$TRUNK" "$STABLE"; do
    for n in $(gh pr list --repo "$REPO" --base "$base" --state open --json number --jq '.[].number'); do
      gh pr close --repo "$REPO" "$n" >/dev/null 2>&1 || true
    done
  done
  # Mergify names a backport branch `mergify/bp/<target>/pr-<n>`.
  for b in $(git ls-remote --heads origin "refs/heads/mergify/bp/${STABLE}/*" | awk '{print $2}' | sed 's#^refs/heads/##'); do
    git push -q origin --delete "$b" >/dev/null 2>&1 || true
  done
  for b in "$HEAD" "$STABLE" "$TRUNK"; do
    git push -q origin --delete "$b" >/dev/null 2>&1 || true
    git branch -D "$b" >/dev/null 2>&1 || true
  done
}

if [ "${1:-}" = "--reset" ]; then
  teardown
  echo "Done. main is untouched."
  exit 0
fi

require_clean_tree

if git ls-remote --exit-code --heads origin "$TRUNK" >/dev/null 2>&1; then
  echo "'${TRUNK}' already exists. Run '$0 --reset' first." >&2
  exit 1
fi

git fetch -q origin main
git checkout -q -B "$TRUNK" origin/main
git push -q origin "$TRUNK"
git push -q origin "origin/main:refs/heads/${STABLE}"

git checkout -q -B "$HEAD" "$TRUNK"
cat >> backend/calculator.py <<'EOF'


def subtract(a: int, b: int) -> int:
    return a - b
EOF
git add backend/calculator.py
git commit -q -m "feat(calculator): add subtract"
git push -q origin "$HEAD"

url=$(gh pr create --repo "$REPO" --base "$TRUNK" --head "$HEAD" \
  --title "feat(calculator): add subtract" \
  --body "Demo for scenarios/backport-activity-log.")
git checkout -q main
n="${url##*/}"
echo "Opened ${url}"

gh pr merge --repo "$REPO" "$n" --squash >/dev/null
for _ in $(seq 1 30); do
  [ "$(gh pr view --repo "$REPO" "$n" --json state --jq .state)" = "MERGED" ] && break
  sleep 2
done
echo "Merged #${n} into ${TRUNK}."

gh pr comment --repo "$REPO" "$n" --body "@mergifyio backport ${STABLE} ${MISSING}" >/dev/null
echo "Asked Mergify to backport #${n} to '${STABLE}' and '${MISSING}' (which does not exist)."
echo
echo "Watch: ${url}"
echo "Then:  https://dashboard.mergify.com/orgs/kozlek/repos/sandbox/activity-log"
