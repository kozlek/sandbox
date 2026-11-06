#!/usr/bin/env bash
#
# Scenario: Mergify retries a test that fails on `main`, and lets a real
# failure stand (test retry, MRGFY-8883).
#
#   run.sh flaky        run the demo workflow on main: the payment test times
#                       out on its first attempt
#   run.sh regression   the same, with a real bug shipped in `refund` too
#   run.sh report [ID]  print the test summary of a run again (default: the
#                       latest demo run)
#
# Test retry only runs in a build of the default branch, so this dispatches
# `test-retry-demo` on `main` itself. It pushes nothing: the workflow and the
# tests are already there. Switching test retry on and off, and tuning it, is
# done on the dashboard; that is the demo.
#
# Requires gh, authenticated as kozlek, and the MERGIFY_TOKEN secret on the
# repository. See README.md for the walkthrough.

set -euo pipefail

REPO="kozlek/sandbox"
WORKFLOW="test-retry-demo.yml"

latest_run() {
  gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 \
    --json databaseId --jq '.[0].databaseId // empty'
}

report() {  # $1 = run id
  # Everything pytest printed from its result lines on: the outcome of each
  # test, then the Mergify blocks, test retry's among them, and the tally.
  gh run view "$1" --repo "$REPO" --log \
    | awk -F'\t' '$2 == "Run tests" { print $3 }' \
    | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//' \
    | sed -n '/::test_/,$p'
}

dispatch() {  # $1 = act
  local url id
  url=$(gh workflow run "$WORKFLOW" --repo "$REPO" --ref main -f act="$1")
  id="${url##*/}"
  if [[ ! "$id" =~ ^[0-9]+$ ]]; then
    echo "gh did not say which run it started; look for it at:" >&2
    echo "  https://github.com/${REPO}/actions/workflows/${WORKFLOW}" >&2
    exit 1
  fi
  echo "Started https://github.com/${REPO}/actions/runs/${id}"
  # The job fails when a test still fails after its retries: that is a result
  # of the demo, not an error of this script.
  gh run watch "$id" --repo "$REPO" --interval 3 --exit-status >/dev/null 2>&1 || true
  echo
  report "$id"
  echo
  echo "Run: https://github.com/${REPO}/actions/runs/${id} ($(gh run view "$id" --repo "$REPO" --json conclusion --jq .conclusion))"
}

case "${1:-}" in
  flaky | regression)
    dispatch "$1"
    ;;

  report)
    id="${2:-$(latest_run)}"
    if [ -z "$id" ]; then
      echo "No demo run yet. Start one with '$0 flaky'." >&2
      exit 1
    fi
    report "$id"
    ;;

  *)
    echo "usage: $0 flaky | regression | report [RUN_ID]" >&2
    exit 1
    ;;
esac
