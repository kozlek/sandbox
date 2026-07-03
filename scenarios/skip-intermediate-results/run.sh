#!/usr/bin/env bash
#
# Scenario: skip_intermediate_results in parallel mode — 4-ancestor chain.
# Opens 5 backend PRs against main. main is never touched.
#   A1..A4 -> each uses a distinct op (op1..op4) that doesn't exist on main,
#             so each FAILS SLOWLY on its own (sleeps ~300s on the missing import).
#   B      -> defines op1..op4; queued LAST so its car is [A1..A4 + B] and passes fast.
# When B's car passes, skip_intermediate_results promotes all four still-pending
# ancestors AT ONCE -> four "Intermediate skipped" badges appear together on the
# Merge Queue dashboard and linger through the sequential merges (5 cars = the
# max_parallel_checks cap, so all run concurrently).
#
#   run.sh           open the PRs
#   run.sh --reset   close them + delete their branches
#
# Run from the set-up sandbox repo. Requires git + gh (authenticated as kozlek).
# This script only CREATES the PRs. Queue them with the reliable order (see the
# scenario README): label A1..A4, WAIT for all to embark, THEN label B last.

set -euo pipefail

BASE="main"
OPS="op1 op2 op3 op4"                 # ancestors: skip-demo/use-<op>
FIX_BRANCH="skip-demo/add-ops"        # B: defines every op, queued last

# Repo root is two levels up from this script.
cd "$(dirname "$0")/../.."

if [ ! -d .git ]; then
  echo "No git repo here. Set up the sandbox repo first (see top-level README)." >&2
  exit 1
fi

close_pr_for() {  # $1 = head branch — best-effort
  gh pr close "$1" --delete-branch >/dev/null 2>&1 || true
}

all_branches() {
  for op in $OPS; do echo "skip-demo/use-$op"; done
  echo "${FIX_BRANCH}"
}

teardown() {
  echo "Closing scenario PRs and deleting branches..."
  for b in $(all_branches); do
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

echo "Opening scenario PRs (4 ancestors + 1 fix)..."

# Ancestors A1..A4 — each uses a distinct op missing on main, failing SLOWLY.
# skip_intermediate_results only promotes ancestors still pending (WAITING_FOR_CI);
# a definitively-failed car parks the chain (NoSkipWithFailure). The ~300s sleep
# keeps each ancestor pending until B's [A1..A4 + B] car passes and promotes them.
for op in $OPS; do
  br="skip-demo/use-$op"
  start_branch "$br"
  cat > "backend/test_$op.py" <<PY
def test_$op() -> None:
    try:
        from backend.calculator import $op
    except ImportError:
        # Missing on main: stall so the failure stays non-definitive until B's
        # combined car passes and skip_intermediate_results promotes this ancestor.
        import time

        time.sleep(300)
        raise
    assert $op(2, 3) == 5
PY
  open_pr "$br" \
    "feat(backend): use $op()" \
    "Uses \`$op()\`, undefined on \`main\` — **fails slowly** (~300s) on its own. The fix PR (\`${FIX_BRANCH}\`) defines it. One of four ancestors promoted at once via \`skip_intermediate_results\`. Backend scope."
done

# B — defines every op. Queue LAST so its car is [A1..A4 + B]: it passes fast
# (all ops present) and promotes all four still-pending ancestors together.
start_branch "${FIX_BRANCH}"
cat > backend/calculator.py <<'PY'
def add(a: int, b: int) -> int:
    return a + b


def op1(a: int, b: int) -> int:
    return a + b


def op2(a: int, b: int) -> int:
    return a + b


def op3(a: int, b: int) -> int:
    return a + b


def op4(a: int, b: int) -> int:
    return a + b
PY
open_pr "${FIX_BRANCH}" \
  "feat(backend): add op1..op4()" \
  "Defines \`op1\`..\`op4\`. Queue this **last**: its car is tested on top of all four ancestors (\`[A1..A4 + B]\`), passes fast, and promotes all four still-pending ancestors at once via \`skip_intermediate_results\` — four 'Intermediate skipped' badges. Backend scope."

echo
echo "Done. Reliable queue order (avoids the parent/child coin-flip):"
echo "  1. label all four ancestors:"
for op in $OPS; do echo "       gh pr edit <use-$op> --add-label queue"; done
echo "  2. WAIT for all four to embark (each gets the 'queued' label)"
echo "  3. THEN label the fix LAST:  gh pr edit <${FIX_BRANCH}> --add-label queue"
echo "Watch the dashboard: when B's car goes green, all four ancestors flash the"
echo "indigo 'Intermediate skipped' badge before merging."
