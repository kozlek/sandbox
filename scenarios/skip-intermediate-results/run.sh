#!/usr/bin/env bash
#
# Scenario: skip_intermediate_results in PARALLEL mode. main is never touched.
# Three PRs, three cars — only the ancestor sleeps, so this is cheap:
#   A -> `backend`; uses multiply() (missing on main) so it FAILS SLOWLY on its
#        own (sleeps ~300s on the missing import), staying WAITING_FOR_CI.
#   B -> `backend`; defines multiply(); queued LAST so its car is [A + B] and
#        passes fast, promoting the still-pending A via skip_intermediate_results.
#   F -> `frontend`; independent car that runs CONCURRENTLY with the backend
#        chain — this is what makes it visibly PARALLEL mode.
#
#   run.sh           open the PRs
#   run.sh --reset   close them + delete their branches
#
# Run from the set-up sandbox repo. Requires git + gh (authenticated as kozlek).
# This script only CREATES the PRs. Queue with the reliable order (see the
# scenario README): label A (+ F), WAIT for A to embark, THEN label B last.
# To catch the transient "Intermediate skipped" badge, open the Batch Peek
# drawer on A's batch the moment B's car goes green.

set -euo pipefail

BASE="main"
BRANCH_A="skip-demo/use-multiply"           # backend ancestor, slow-fail
BRANCH_B="skip-demo/add-multiply"           # backend fix, queued last
BRANCH_F="skip-demo/frontend-greeting"      # frontend, parallel car

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
  for b in "${BRANCH_A}" "${BRANCH_B}" "${BRANCH_F}"; do
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

echo "Opening scenario PRs (backend A + backend B + frontend F)..."

# A — backend ancestor. Uses multiply() (missing on main), failing SLOWLY.
# skip_intermediate_results only promotes ancestors still pending (WAITING_FOR_CI);
# a definitively-failed car parks the chain (NoSkipWithFailure). The ~300s sleep
# keeps A pending until B's [A + B] car passes and promotes it.
start_branch "${BRANCH_A}"
cat > backend/test_multiply.py <<'PY'
def test_multiply() -> None:
    try:
        from backend.calculator import multiply
    except ImportError:
        # Missing on main: stall so the failure stays non-definitive until B's
        # [A + B] car passes and skip_intermediate_results promotes A.
        import time

        time.sleep(300)
        raise
    assert multiply(2, 3) == 6
PY
open_pr "${BRANCH_A}" \
  "feat(backend): use multiply()" \
  "Uses \`multiply()\`, undefined on \`main\` — so **A alone fails, but slowly** (~300s on the missing import). Its fix (\`${BRANCH_B}\`) adds \`multiply()\`, so the \`[A + B]\` car passes fast and \`skip_intermediate_results\` promotes A while its own check is still pending. Backend scope."

# B — the fix. Queue LAST so its car is [A + B]: it passes fast and promotes the
# still-pending A.
start_branch "${BRANCH_B}"
cat > backend/calculator.py <<'PY'
def add(a: int, b: int) -> int:
    return a + b


def multiply(a: int, b: int) -> int:
    return a * b
PY
open_pr "${BRANCH_B}" \
  "feat(backend): add multiply()" \
  "Defines \`multiply()\`. Queue this **last**: its car is \`[A + B]\`, passes fast, and promotes the still-pending ancestor A via \`skip_intermediate_results\` (A merges with no CI of its own). Backend scope."

# F — frontend, independent scope. Its car runs CONCURRENTLY with the backend
# chain: this is what makes the run visibly PARALLEL mode. No skip — it passes
# and merges on its own car.
start_branch "${BRANCH_F}"
cat > frontend/widget.py <<'PY'
def greeting() -> str:
    return "hello world"
PY
cat > frontend/test_widget.py <<'PY'
from frontend.widget import greeting


def test_greeting() -> None:
    assert greeting() == "hello world"
PY
open_pr "${BRANCH_F}" \
  "feat(frontend): greeting -> hello world" \
  "Independent change in the \`frontend\` scope — its car runs in parallel with the backend chain, making PARALLEL mode visible. No skip: it passes and merges on its own car. Frontend scope."

echo
echo "Done. Reliable queue order (avoids the parent/child coin-flip):"
echo "  1. label A and F:   gh pr edit <use-multiply> --add-label queue"
echo "                      gh pr edit <frontend-greeting> --add-label queue   # parallel"
echo "  2. WAIT for A to embark (it gets the 'queued' label)"
echo "  3. THEN label B last:  gh pr edit <add-multiply> --add-label queue"
echo "When B's car goes green, A merges with no CI of its own; open the Batch Peek"
echo "drawer on A's batch to hold the indigo 'Intermediate skipped' badge in view."
