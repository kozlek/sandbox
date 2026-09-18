#!/usr/bin/env bash
#
# Scenario: the merge queue names the check that failed, not one still running
# (MRGFY-8607, engine #38516 / #38517 / #38518).
#
#   run.sh start       open the PR, report `security-scan` green on it, label it
#                      `checks-demo` so the `checks-demo` queue rule picks it up
#   run.sh fail-scan   flip `security-scan` to failure on the PR while the queue
#                      is still running `ci` on the draft
#   run.sh --reset     close every PR of the scenario and delete its branches
#
# Everything targets the throwaway base branch `fca/trunk`, never `main`: if
# the presenter never runs `fail-scan`, the queue merges the PR, and it must
# not land its deliberately slow test on `main`.
#
# Requires git + gh (authenticated as kozlek) and the `checks-demo` queue rule
# in the root .mergify.yml. See README.md for the walkthrough.

set -euo pipefail

REPO="kozlek/sandbox"
TRUNK="fca/trunk"
HEAD="fca/change"
LABEL="checks-demo"
STATUS_CONTEXT="security-scan"

cd "$(dirname "$0")/../.."

push() {  # git push, without GitHub's "Create a pull request" banner
  local out
  if ! out=$(git push -q "$@" 2>&1); then
    echo "$out" >&2
    return 1
  fi
}

require_clean_tree() {
  # The script commits on scratch branches; a modified tracked file would ride
  # along into them.
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "The working tree has uncommitted changes. Commit or stash them first." >&2
    exit 1
  fi
}

pr_number() {
  gh pr list --repo "$REPO" --head "$HEAD" --state open --json number --jq '.[0].number // empty'
}

post_status() {  # $1 = sha, $2 = state, $3 = description
  gh api --silent "repos/${REPO}/statuses/$1" \
    -f state="$2" \
    -f context="$STATUS_CONTEXT" \
    -f description="$3" \
    -f target_url="https://github.com/${REPO}/blob/main/scenarios/failing-check-attribution/README.md"
}

teardown() {
  echo "Closing scenario PRs and deleting branches..."
  # The draft first: the queue owns it, and closing the user PR first makes the
  # queue report a dequeue the next run would have to wait out.
  for n in $(gh pr list --repo "$REPO" --base "$TRUNK" --state open --json number --jq '.[].number'); do
    gh pr close --repo "$REPO" "$n" >/dev/null 2>&1 || true
  done
  for b in "$HEAD" "$TRUNK"; do
    git push -q origin --delete "$b" >/dev/null 2>&1 || true
    git branch -D "$b" >/dev/null 2>&1 || true
  done
}

case "${1:-}" in
  --reset)
    teardown
    echo "Done. main is untouched."
    ;;

  start)
    require_clean_tree
    if [ -n "$(pr_number)" ]; then
      echo "A scenario PR is already open. Run '$0 --reset' first." >&2
      exit 1
    fi
    gh label create "$LABEL" --repo "$REPO" --color 5319e7 \
      --description "Queue with the checks-demo rule" --force >/dev/null

    git fetch -q origin main
    git checkout -q -B "$TRUNK" origin/main
    push -f origin "$TRUNK"

    git checkout -q -B "$HEAD" "$TRUNK"
    cat > backend/test_integration_suite.py <<'EOF'
"""A long integration suite: keeps `ci` running while the queue tests the PR."""

import time


def test_integration_suite() -> None:
    time.sleep(240)
EOF
    git add backend/test_integration_suite.py
    git commit -q -m "test: add the integration suite"
    push -f origin "$HEAD"

    url=$(gh pr create --repo "$REPO" --base "$TRUNK" --head "$HEAD" \
      --title "test: add the integration suite" \
      --body "Demo for scenarios/failing-check-attribution. Queued by the \`checks-demo\` rule.")
    sha=$(git rev-parse HEAD)
    post_status "$sha" success "No findings"
    gh pr edit --repo "$REPO" "$url" --add-label "$LABEL" >/dev/null
    git checkout -q main

    echo "Opened ${url}"
    echo "security-scan is green on ${sha:0:7}, and the PR carries the '${LABEL}' label."
    echo "Wait for the draft PR and its 'ci' run, then: $0 fail-scan"
    ;;

  fail-scan)
    n=$(pr_number)
    if [ -z "$n" ]; then
      echo "No scenario PR is open. Run '$0 start' first." >&2
      exit 1
    fi
    sha=$(gh pr view --repo "$REPO" "$n" --json headRefOid --jq .headRefOid)
    draft=$(gh pr list --repo "$REPO" --base "$TRUNK" --state open \
      --json number,headRefName --jq '[.[] | select(.headRefName | startswith("mergify/merge-queue/"))][0].number // empty')
    if [ -z "$draft" ]; then
      echo "No draft PR yet: the queue has not started testing #${n}." >&2
      echo "Failing the scan now would dequeue it before 'ci' is running, which shows nothing." >&2
      exit 1
    fi
    post_status "$sha" failure "1 critical finding"
    echo "security-scan is now failing on #${n} (${sha:0:7}); 'ci' is still running on draft #${draft}."
    echo "Watch the Mergify comment on https://github.com/${REPO}/pull/${n}"
    ;;

  *)
    echo "usage: $0 start | fail-scan | --reset" >&2
    exit 1
    ;;
esac
