#!/usr/bin/env bash
#
# Scenario: the engine lists a pull request's changed files with git once GitHub
# truncates its own list (MRGFY-7706, flag CHANGED_FILES_FROM_GIT_FOR_ORGS).
#
#   run.sh setup     open the 3 501-file probe PR and print what GitHub's API
#                    answers about it (changed_files vs. the truncated list)
#   run.sh go        label the probe so the `bigdiff-probe` queue rule evaluates
#   run.sh --reset   close the PR, drop the label and delete the branches
#
# The probe targets a throwaway base branch, never `main`.
#
# Requires git + gh (authenticated as kozlek). See README.md for the walkthrough.

set -euo pipefail

REPO="kozlek/sandbox"
BASE="bigdiff/base"
HEAD="bigdiff/head"
LABEL="bigdiff-probe"
MARKER="zzz-past-the-cap.txt"
BULK=3500

cd "$(dirname "$0")/../.."

require_clean_tree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "The working tree has uncommitted changes. Commit or stash them first." >&2
    exit 1
  fi
}

teardown() {
  echo "Closing the probe and deleting its branches..."
  gh pr close --repo "$REPO" "$HEAD" >/dev/null 2>&1 || true
  for b in "$HEAD" "$BASE"; do
    git push -q origin --delete "$b" >/dev/null 2>&1 || true
    git branch -D "$b" >/dev/null 2>&1 || true
  done
}

probe_pr_number() {
  gh pr list --repo "$REPO" --head "$HEAD" --state open --json number --jq '.[0].number'
}

setup() {
  require_clean_tree
  teardown

  git checkout -q -B "$BASE" origin/main
  git push -q origin "$BASE"

  git checkout -q -B "$HEAD" "$BASE"
  mkdir -p bulk
  seq -w 1 "$BULK" | while read -r n; do
    printf 'bulk file %s\n' "$n" > "bulk/f${n}.txt"
  done
  printf 'The last entry of the diff, past GitHub 3 000-file cap.\n' > "$MARKER"
  git add bulk "$MARKER"
  git commit -q -m "probe: $((BULK + 1)) changed files, one past GitHub's cap"
  git push -q origin "$HEAD"
  git checkout -q main

  gh pr create --repo "$REPO" --base "$BASE" --head "$HEAD" \
    --title "probe: $((BULK + 1)) changed files" \
    --body "Probe for scenarios/changed-files-from-git. Never merged; drop the \`$LABEL\` label to dequeue it." >/dev/null

  local pr
  pr=$(probe_pr_number)
  echo
  echo "Probe PR: https://github.com/$REPO/pull/$pr"
  echo "  changed_files reported by GitHub: $(gh api "repos/$REPO/pulls/$pr" --jq .changed_files)"
  local listed
  listed=$(gh api --paginate "repos/$REPO/pulls/$pr/files?per_page=100" --jq '.[].filename' | wc -l | tr -d ' ')
  echo "  entries GET /pulls/$pr/files returns: $listed"
  echo -n "  $MARKER present in that list: "
  if gh api --paginate "repos/$REPO/pulls/$pr/files?per_page=100" --jq '.[].filename' | grep -qx "$MARKER"; then
    echo "yes -- pick a different marker, this one is not past the cap"
  else
    echo "no -- only a git-derived list can match it"
  fi
}

go() {
  gh label create "$LABEL" --repo "$REPO" --color 0E8A16 \
    --description "Queue with the bigdiff-probe rule" >/dev/null 2>&1 || true
  gh pr edit --repo "$REPO" "$(probe_pr_number)" --add-label "$LABEL" >/dev/null
  echo "Labelled. The rule admits the probe only if the engine read the complete list."
}

case "${1:-}" in
  setup) setup ;;
  go) go ;;
  --reset) teardown ;;
  *) sed -n '3,12p' "$0" >&2; exit 1 ;;
esac
