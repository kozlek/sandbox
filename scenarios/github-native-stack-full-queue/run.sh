#!/usr/bin/env bash
#
# Scenario: full-stack queueing of a GitHub-native stack. main is never touched
# by this script (the root .mergify.yml swap is a separate, deliberate commit).
#
# Builds a 2-member GitHub-native stack:
#   1 (bottom) -> base main
#   2 (upper)  -> base <bottom branch>, so it physically chains
# then makes them a real native stack with POST /repos/{o}/{r}/stacks.
#
#   run.sh           open the PRs and create the stack
#   run.sh --reset   close them + delete their branches
#
# Requires git + gh (authenticated as kozlek). See README.md for the walkthrough.

set -euo pipefail

BASE="main"
BRANCH_1="gh-fq-1"
BRANCH_2="gh-fq-2"
REPO="kozlek/sandbox"

cd "$(dirname "$0")/../.."

if [ ! -d .git ]; then
  echo "No git repo here. Set up the sandbox repo first (see top-level README)." >&2
  exit 1
fi

close_pr_for() {  # $1 = head branch — best-effort
  gh pr close "$1" --delete-branch >/dev/null 2>&1 || true
}

teardown() {
  echo "Closing scenario PRs and deleting branches..."
  # Upper first: deleting the bottom's branch while the upper still targets it
  # CLOSES the upper outright (base_ref_deleted), which muddies a re-run.
  for b in "${BRANCH_2}" "${BRANCH_1}"; do
    close_pr_for "$b"
    git push origin --delete "$b" >/dev/null 2>&1 || true
    git branch -D "$b" >/dev/null 2>&1 || true
  done
}

if [ "${1:-}" = "--reset" ]; then
  teardown
  echo "Done. main is untouched."
  exit 0
fi

git fetch -q origin "${BASE}"
git checkout -q "${BASE}"
git pull -q --ff-only origin "${BASE}" || true

# --- bottom -------------------------------------------------------------------
close_pr_for "${BRANCH_1}"
git branch -D "${BRANCH_1}" >/dev/null 2>&1 || true
git checkout -q -B "${BRANCH_1}" "origin/${BASE}"
cat > backend/fq_bottom.py <<'PY'
def fq_bottom() -> str:
    return "bottom"
PY
git add -A
git commit -q -m "exp(fq): bottom member"
git push -fq origin "${BRANCH_1}"
PR_1=$(gh pr create --repo "${REPO}" --base "${BASE}" --head "${BRANCH_1}" \
  --title "exp(fq): bottom member" \
  --body "Bottom of a 2-member GitHub-native stack. Full-stack queueing scenario." \
  | sed 's#.*/##')
echo "  opened bottom: #${PR_1} (${BRANCH_1})"

# --- upper, chained onto the bottom ------------------------------------------
close_pr_for "${BRANCH_2}"
git branch -D "${BRANCH_2}" >/dev/null 2>&1 || true
git checkout -q -B "${BRANCH_2}" "${BRANCH_1}"
cat > backend/fq_upper.py <<'PY'
def fq_upper() -> str:
    return "upper"
PY
git add -A
git commit -q -m "exp(fq): upper member"
git push -fq origin "${BRANCH_2}"
PR_2=$(gh pr create --repo "${REPO}" --base "${BRANCH_1}" --head "${BRANCH_2}" \
  --title "exp(fq): upper member" \
  --body "Upper member, chained onto #${PR_1}. Full-stack queueing scenario." \
  | sed 's#.*/##')
echo "  opened upper:  #${PR_2} (${BRANCH_2})"

git checkout -q "${BASE}"

# --- make it a real GitHub-native stack --------------------------------------
# `-F` sends typed ints; plain `-f` sends strings and the endpoint 422s.
# POST /stacks needs >= 2 pull requests (single-PR stacks are no longer
# creatable). Undocumented preview endpoint — no special Accept header needed.
echo "Creating the native stack over #${PR_1} + #${PR_2}..."
STACK=$(gh api "repos/${REPO}/stacks" \
  -F "pull_requests[]=${PR_1}" \
  -F "pull_requests[]=${PR_2}" \
  --jq '.number')
echo "  stack #${STACK}"

echo
echo "Queue bottom-up, and hold the gate until BOTH are embarked:"
echo "  gh pr edit ${PR_1} --repo ${REPO} --add-label queue"
echo "  gh pr edit ${PR_2} --repo ${REPO} --add-label queue"
echo "Then watch, and only release the bottom's gate once the upper is queued:"
echo "  scenarios/github-native-stack-full-queue/watch.sh ${PR_1} ${PR_2}"
