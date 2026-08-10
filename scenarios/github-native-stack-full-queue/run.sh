#!/usr/bin/env bash
#
# Scenario: full-stack queueing of a GitHub-native stack. main is never touched
# by this script (the root .mergify.yml swap is a separate, deliberate commit).
#
#   run.sh [N]       open an N-member stack (default 3, minimum 2)
#   run.sh --reset   close the fixtures + delete their branches
#
# Builds an N-member GitHub-native stack, each member based on the one below it:
#   gh-fq-1 -> main, gh-fq-2 -> gh-fq-1, ... gh-fq-N -> gh-fq-(N-1)
# then makes them a real native stack with POST /repos/{o}/{r}/stacks.
#
# EVERY MEMBER APPENDS TO THE SAME FILE (backend/chain.py) on purpose. Run 1 used
# disjoint files and GitHub only RETARGETED the survivor -- head SHA untouched, so
# the queue's synchronize detector was never reached and the cascade-rebase shape
# (the one PR #38244/#38246 exist for) went unobserved. Overlapping content makes
# each member's branch genuinely diverge from the post-landing base, which is the
# condition most likely to force a real rebase. Appends stay REBASE-CLEAN: member
# i's commit adds its own function after member i-1's, and the landed base already
# contains i-1's, so replaying i applies without conflict.
#
# Requires git + gh (authenticated as kozlek). See README.md for the walkthrough.

set -euo pipefail

BASE="main"
REPO="kozlek/sandbox"
PREFIX="gh-fq"
MAX_TEARDOWN=12   # teardown sweeps a generous range so any past run is cleaned

cd "$(dirname "$0")/../.."

if [ ! -d .git ]; then
  echo "No git repo here. Set up the sandbox repo first (see top-level README)." >&2
  exit 1
fi

close_pr_for() {  # $1 = head branch — best-effort
  gh pr close "$1" --delete-branch >/dev/null 2>&1 || true
}

teardown() {
  echo "Closing scenario PRs and deleting branches (top-down)..."
  # Top-down on purpose: deleting a lower member's branch while an upper still
  # targets it CLOSES the upper outright (base_ref_deleted), which makes the next
  # run's state confusing.
  for i in $(seq "${MAX_TEARDOWN}" -1 1); do
    b="${PREFIX}-${i}"
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

N="${1:-3}"
if ! [ "$N" -ge 2 ] 2>/dev/null; then
  echo "Member count must be an integer >= 2 (POST /stacks refuses a single-PR stack)." >&2
  exit 1
fi

git fetch -q origin "${BASE}"
git checkout -q "${BASE}"
git pull -q --ff-only origin "${BASE}" || true

PRS=()
for i in $(seq 1 "$N"); do
  branch="${PREFIX}-${i}"
  if [ "$i" -eq 1 ]; then
    parent_ref="origin/${BASE}"
    parent_base="${BASE}"
  else
    parent_ref="${PREFIX}-$((i - 1))"
    parent_base="${PREFIX}-$((i - 1))"
  fi

  close_pr_for "$branch"
  git branch -D "$branch" >/dev/null 2>&1 || true
  git checkout -q -B "$branch" "$parent_ref"

  # Same file for every member — see the header note on why this matters.
  mkdir -p backend
  if [ "$i" -eq 1 ]; then
    printf '"""Chain fixture: one function appended per stack member."""\n' \
      > backend/chain.py
  fi
  cat >> backend/chain.py <<PY


def link_${i}() -> int:
    return ${i}
PY

  git add -A
  git commit -q -m "exp(fq): member ${i} of ${N}"
  git push -fq origin "$branch"
  pr=$(gh pr create --repo "${REPO}" --base "${parent_base}" --head "$branch" \
    --title "exp(fq): member ${i} of ${N}" \
    --body "Member ${i} of an ${N}-member GitHub-native stack. Appends \`link_${i}()\` to \`backend/chain.py\` — every member touches the SAME file so the survivors genuinely diverge from the post-landing base." \
    | sed 's#.*/##')
  PRS+=("$pr")
  echo "  opened member ${i}: #${pr} (${branch}, base ${parent_base})"
done

git checkout -q "${BASE}"

# --- make it a real GitHub-native stack --------------------------------------
# `-F` sends typed ints; plain `-f` sends strings and the endpoint 422s.
# POST /stacks needs >= 2 pull requests (single-PR stacks are no longer creatable).
# Undocumented preview endpoint — no special Accept header needed.
echo "Creating the native stack over ${PRS[*]}..."
args=()
for pr in "${PRS[@]}"; do args+=(-F "pull_requests[]=${pr}"); done
STACK=$(gh api "repos/${REPO}/stacks" "${args[@]}" --jq '.number')
echo "  stack #${STACK}"

echo
echo "Queue every member, bottom-up:"
for pr in "${PRS[@]}"; do
  echo "  gh pr edit ${pr} --repo ${REPO} --add-label queue"
done
echo "Arm the instrument FIRST, then label:"
echo "  scenarios/github-native-stack-full-queue/watch.sh ${PRS[*]}"
