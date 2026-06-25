#!/usr/bin/env bash
#
# Scenario: skip_intermediate_results in parallel mode.
# Opens three throwaway PRs against main. main is never touched.
#   A, B  -> `backend` scope chain (the skip fires here)
#   C     -> `frontend` scope, runs in parallel (makes it visibly parallel mode)
#
#   run.sh           open PRs A, B, C
#   run.sh --reset   close them + delete their branches
#
# Run from the set-up sandbox repo. Requires git + gh (authenticated as kozlek).

set -euo pipefail

BASE="main"
BRANCH_A="skip-demo/use-multiply"        # backend, broken on its own
BRANCH_B="skip-demo/add-multiply"        # backend, the fix — child of A
BRANCH_C="skip-demo/frontend-greeting"   # frontend, independent parallel scope

# Repo root is two levels up from this script.
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
  for b in "${BRANCH_A}" "${BRANCH_B}" "${BRANCH_C}"; do
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

start_branch() {  # $1 branch — fresh off origin/main
  local branch="$1"
  close_pr_for "$branch"
  git branch -D "$branch" >/dev/null 2>&1 || true
  git checkout -q -B "$branch" "origin/${BASE}"
}

open_pr() {  # $1 branch  $2 commit/title  $3 body
  local branch="$1" title="$2" body="$3"
  git add -A
  git commit -q -m "$title"
  git push -fu origin "$branch" >/dev/null
  gh pr create --base "${BASE}" --head "$branch" --title "$title" --body "$body" >/dev/null
  echo "  opened: $title  ($branch)"
  git checkout -q "${BASE}"
}

echo "Opening scenario PRs..."

# PR A — backend, red on its own (uses multiply() before it exists).
start_branch "${BRANCH_A}"
cat > backend/test_multiply.py <<'PY'
from backend.calculator import multiply


def test_multiply() -> None:
    assert multiply(2, 3) == 6
PY
open_pr "${BRANCH_A}" \
  "feat(backend): use multiply()" \
  "Adds a test for \`multiply()\`. **Red on its own** — \`multiply\` doesn't exist on \`main\` yet; it only passes combined with its child PR (\`${BRANCH_B}\`). Backend scope."

# PR B — backend, the fix (defines multiply); tested as A+B in the chain.
start_branch "${BRANCH_B}"
cat > backend/calculator.py <<'PY'
def add(a: int, b: int) -> int:
    return a + b


def multiply(a: int, b: int) -> int:
    return a * b
PY
open_pr "${BRANCH_B}" \
  "feat(backend): add multiply()" \
  "Defines \`multiply()\`. Queued **after** PR A in the \`backend\` scope, so it's tested as **A+B**, goes green, and promotes A via \`skip_intermediate_results\`. Backend scope."

# PR C — frontend, independent parallel scope (makes parallel mode visible).
start_branch "${BRANCH_C}"
cat > frontend/widget.py <<'PY'
def greeting() -> str:
    return "hello world"
PY
cat > frontend/test_widget.py <<'PY'
from frontend.widget import greeting


def test_greeting() -> None:
    assert greeting() == "hello world"
PY
open_pr "${BRANCH_C}" \
  "feat(frontend): greeting -> hello world" \
  "Independent change in the \`frontend\` scope — runs as its own parallel car alongside the backend chain. Frontend scope."

echo
echo "Done. Queue them in order (A -> B -> C):"
echo "  gh pr edit <A> --add-label queue   # ${BRANCH_A}"
echo "  gh pr edit <B> --add-label queue   # ${BRANCH_B}"
echo "  gh pr edit <C> --add-label queue   # ${BRANCH_C}"
echo "See scenarios/skip-intermediate-results/README.md for the live walkthrough."
