#!/usr/bin/env bash
#
# Scenario: test retry saves a merge queue batch from a flaky test (test retry
# in the merge queue, MRGFY-12316, the CI plugins' 2026.11.12 or later).
#
#   run.sh open           cut the throwaway trunk `trq/trunk` from main, open
#                         three pull requests into it, and wait for each one's
#                         own `checkout-tests` run to pass
#   run.sh queue          label all three `trq-queue`: they fill one batch,
#                         checked on one draft. Prints the draft run's test
#                         summary, then follows the batch to its end
#   run.sh report [RUN]   print a run's test summary again (default: the
#                         latest run of a queue draft)
#   run.sh --reset        close the scenario's pull requests, delete its
#                         branches and the trunk
#
# Nothing here touches `main`. Switching test retry on and off is done on the
# dashboard.
#
# Requires gh, authenticated as kozlek, and on `main`: the `retry-demo` queue
# rule and .github/workflows/test-retry-queue-demo.yml, and a trust policy of
# kozlek that lets the job in with its ID token. See README.md for the
# walkthrough.

set -euo pipefail

REPO="kozlek/sandbox"
TRUNK="trq/trunk"
LABEL="trq-queue"
CHECK="checkout-tests"
WORKFLOW="test-retry-queue-demo.yml"
DRAFT_PREFIX="mergify/merge-queue/"
COPY_DIR="scenarios/test-retry-merge-queue/copy"

# One pull request per line: branch|file|title|the copy it adds. Each adds its
# own file, so the three never conflict in a batch.
PULLS=(
  "trq/gift-cards|gift-cards.md|copy(checkout): explain gift cards at checkout|A gift card pays for all or part of an order. What it does not cover goes on your card."
  "trq/shipping-banner|shipping-banner.md|copy(checkout): announce free shipping from 50.00|Free shipping from 50.00. Below that, a flat 4.90."
  "trq/refund-policy|refund-policy.md|copy(checkout): state the restocking fee|A refund holds back a 10% restocking fee on opened items."
)

# gh 2.105 follows every call naming a pull request with a hint about
# `gh event listen` on stderr, which would bury the demo's output. Drop it,
# keep any other error.
gh() {
  command gh "$@" 2> >(sed '/^hint: if you need to wait for this pull request/,/^  - Event subscriptions are in preview/d' >&2)
}

ref_sha() {  # $1 = branch. Its SHA, empty when it does not exist.
  gh api "repos/${REPO}/git/ref/heads/$1" --jq .object.sha 2>/dev/null || true
}

put_ref() {  # $1 = branch, $2 = SHA: create the branch there, or move it there
  gh api -X PATCH "repos/${REPO}/git/refs/heads/$1" -f sha="$2" -F force=true >/dev/null 2>&1 \
    || gh api -X POST "repos/${REPO}/git/refs" -f ref="refs/heads/$1" -f sha="$2" >/dev/null
}

trunk_pulls() {  # $1 = jq test on the head branch. The open PRs into the trunk it matches.
  gh pr list --repo "$REPO" --base "$TRUNK" --state open --limit 100 \
    --json number,headRefName --jq ".[] | select(.headRefName | $1) | .number"
}

scenario_pulls() {
  trunk_pulls 'startswith("trq/")' | sort -n
}

check_run() {  # $1 = SHA. Its completed `checkout-tests` run: conclusion and URL, empty until then.
  gh api -X GET "repos/${REPO}/commits/$1/check-runs" -f check_name="$CHECK" \
    --jq '[.check_runs[] | select(.status == "completed")][0] // empty | "\(.conclusion) \(.details_url)"'
}

wait_check() {  # $1 = SHA, $2 = what to call it. Prints "conclusion url".
  local result=""
  for _ in $(seq 60); do
    result=$(check_run "$1")
    [ -n "$result" ] && break
    sleep 5
  done
  if [ -z "$result" ]; then
    echo "No ${CHECK} result for $2 after 5 minutes: look at https://github.com/${REPO}/actions/workflows/${WORKFLOW}" >&2
    exit 1
  fi
  echo "$result"
}

run_id() {  # $1 = a check run's details URL: .../actions/runs/<id>/job/<job>
  echo "$1" | sed -E 's#.*/actions/runs/([0-9]+)/.*#\1#'
}

report() {  # $1 = run id
  # Everything pytest printed from its result lines on: the outcome of each
  # test, then the Mergify blocks, test retry's among them, and the tally.
  gh run view "$1" --repo "$REPO" --log \
    | awk -F'\t' '$2 == "Run tests" { print $3 }' \
    | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//' \
    | sed -n '/::test_/,$p'
}

latest_draft_run() {
  gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 20 \
    --json databaseId,headBranch \
    --jq "[.[] | select(.headBranch | startswith(\"${DRAFT_PREFIX}\"))][0].databaseId // empty"
}

teardown() {
  echo "Closing the scenario's pull requests and deleting its branches..."
  # The queue's drafts too: they target the trunk.
  for n in $(trunk_pulls 'true'); do
    gh pr close --repo "$REPO" "$n" >/dev/null 2>&1 || true
  done
  for entry in "${PULLS[@]}"; do
    gh api -X DELETE "repos/${REPO}/git/refs/heads/${entry%%|*}" >/dev/null 2>&1 || true
  done
  gh api -X DELETE "repos/${REPO}/git/refs/heads/${TRUNK}" >/dev/null 2>&1 || true
}

case "${1:-}" in
  --reset)
    teardown
    echo "Done. main is untouched."
    ;;

  open)
    if [ -n "$(trunk_pulls 'true')" ]; then
      echo "Pull requests into ${TRUNK} are still open. Run '$0 --reset' first." >&2
      exit 1
    fi
    gh label create "$LABEL" --repo "$REPO" --color 5319e7 \
      --description "Queue with the retry-demo rule" --force >/dev/null

    trunk=$(ref_sha main)
    put_ref "$TRUNK" "$trunk"
    echo "${TRUNK} cut from main at ${trunk:0:7}."

    pulls=()
    for entry in "${PULLS[@]}"; do
      IFS='|' read -r branch file title text <<<"$entry"
      put_ref "$branch" "$trunk"
      gh api -X PUT "repos/${REPO}/contents/${COPY_DIR}/${file}" \
        -f message="$title" \
        -f content="$(printf '%s\n' "$text" | base64 | tr -d '\n')" \
        -f branch="$branch" >/dev/null
      url=$(gh pr create --repo "$REPO" --base "$TRUNK" --head "$branch" \
        --title "$title" --body "scenarios/test-retry-merge-queue: one of three pull requests the merge queue batches.")
      pulls+=("${url##*/}")
      echo "Opened ${url}"
    done

    echo "Waiting for each pull request's own ${CHECK}..."
    for n in "${pulls[@]}"; do
      head=$(gh pr view --repo "$REPO" "$n" --json headRefOid --jq .headRefOid)
      result=$(wait_check "$head" "#$n") || exit 1
      read -r conclusion _ <<<"$result"
      echo "#$n: ${CHECK} ${conclusion}"
    done
    echo "Next: $0 queue"
    ;;

  queue)
    mapfile -t pulls < <(scenario_pulls)
    if [ "${#pulls[@]}" -ne "${#PULLS[@]}" ]; then
      echo "Expected ${#PULLS[@]} open pull requests into ${TRUNK}, found ${#pulls[@]}. Run '$0 open' first." >&2
      exit 1
    fi
    for n in "${pulls[@]}"; do
      gh pr edit --repo "$REPO" "$n" --add-label "$LABEL" >/dev/null
    done
    queued="${pulls[*]}"
    echo "Queued #${queued// /, #} with the retry-demo rule. Waiting for the batch's draft..."

    draft=""
    for _ in $(seq 36); do
      draft=$(trunk_pulls "startswith(\"${DRAFT_PREFIX}\")" | head -n 1)
      [ -n "$draft" ] && break
      sleep 5
    done
    if [ -z "$draft" ]; then
      echo "No draft into ${TRUNK} after 3 minutes: look at the queue on the dashboard." >&2
      exit 1
    fi
    head=$(gh pr view --repo "$REPO" "$draft" --json headRefOid --jq .headRefOid)
    echo "Batch draft: https://github.com/${REPO}/pull/${draft}"

    result=$(wait_check "$head" "the draft #${draft}") || exit 1
    read -r conclusion url <<<"$result"
    echo
    report "$(run_id "$url")"
    echo
    echo "Draft run: ${url} (${conclusion})"

    if [ "$conclusion" != "success" ]; then
      echo "The batch failed. The queue now splits it and checks the parts again: follow it on the dashboard."
      exit 0
    fi
    echo "Waiting for the batch to merge..."
    for _ in $(seq 36); do
      merged=0
      for n in "${pulls[@]}"; do
        [ "$(gh pr view --repo "$REPO" "$n" --json state --jq .state)" = "MERGED" ] && merged=$((merged + 1))
      done
      [ "$merged" -eq "${#pulls[@]}" ] && break
      sleep 5
    done
    for n in "${pulls[@]}"; do
      echo "#$n: $(gh pr view --repo "$REPO" "$n" --json state --jq .state)"
    done
    ;;

  report)
    id="${2:-$(latest_draft_run)}"
    if [ -z "$id" ]; then
      echo "No draft run yet. Start one with '$0 open', then '$0 queue'." >&2
      exit 1
    fi
    report "$id"
    ;;

  *)
    echo "usage: $0 open | queue | report [RUN_ID] | --reset" >&2
    exit 1
    ;;
esac
