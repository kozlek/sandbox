#!/usr/bin/env bash
#
# Scenario: stack-squash-orphans  (reproduces MRGFY-7739).
#
# Pushes a 3-PR `mergify-cli` stack against main. main is never touched.
#   P1 (orphan_a) -> P2 (orphan_b) -> P3 (orphan_c)
# Each PR is a single Change-Id'd commit adding a disjoint backend module, so
# they never conflict and every parent squash-merges cleanly.
#
#   run.sh           build + push the stack (opens P1, P2, P3)
#   run.sh --reset   close the stack PRs + delete their branches
#
# Requires: git, gh (authenticated as kozlek), and the `mergify` CLI.
# Prereqs, the config swap, and the full walkthrough live in this scenario's
# README.md. In particular this scenario needs `merge_method: squash` — swap the
# repo-root .mergify.yml to ./mergify.yml before running.

set -euo pipefail

BASE="main"
STACK_BRANCH="stack-orphans/demo"   # the single local branch the stack is built on
TITLE_TAG="stack-orphans"           # marker in PR titles so --reset can find them

# Repo root is two levels up from this script.
cd "$(dirname "$0")/../.."

if [ ! -d .git ]; then
  echo "No git repo here. Set up the sandbox repo first (see top-level README)." >&2
  exit 1
fi

# A fresh Change-Id per commit per run, so each run opens NEW PRs rather than
# colliding with closed ones from a previous run.
new_change_id() { echo "I$(openssl rand -hex 20)"; }

teardown() {
  echo "Closing stack PRs (title contains '${TITLE_TAG}') and deleting branches..."
  gh pr list --state open --search "${TITLE_TAG} in:title" --json number \
    --jq '.[].number' 2>/dev/null | while read -r n; do
      [ -n "${n}" ] && gh pr close "${n}" --delete-branch >/dev/null 2>&1 || true
  done
  git checkout -q "${BASE}" 2>/dev/null || true
  git branch -D "${STACK_BRANCH}" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--reset" ]; then
  teardown
  echo "Done. main is untouched."
  exit 0
fi

git fetch -q origin "${BASE}"
git checkout -q -B "${STACK_BRANCH}" "origin/${BASE}"

commit_pr() {  # $1 = module name -> adds backend/<m>.py + its test, one Change-Id'd commit
  local m="$1"
  cat > "backend/${m}.py" <<PY
def ${m}() -> str:
    return "${m}"
PY
  cat > "backend/test_${m}.py" <<PY
from backend.${m} import ${m}


def test_${m}() -> None:
    assert ${m}() == "${m}"
PY
  git add -A
  git commit -q -m "${TITLE_TAG}: add backend ${m}" -m "Change-Id: $(new_change_id)"
}

echo "Building the stack (3 commits)..."
commit_pr "orphan_a"   # P1 — bottom of the stack
commit_pr "orphan_b"   # P2 — child of P1
commit_pr "orphan_c"   # P3 — the PR we observe (child of P2)

echo "Pushing the stack with mergify-cli..."
mergify stack push

echo
echo "Done. Stack opened: P1(orphan_a) -> P2(orphan_b) -> P3(orphan_c)."
echo "Follow scenarios/stack-squash-orphans/README.md:"
echo "  1. Queue the PARENTS only:  gh pr edit <P1> <P2> --add-label queue"
echo "  2. After they squash-merge, inspect P3 — it should show 3 commits, never rebased."
echo "  3. Then queue P3 and confirm its squash on main is a single clean commit."
