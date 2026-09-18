#!/usr/bin/env bash
#
# Scenario: what GitHub refuses a GitHub App that lacks the `workflows`
# permission (MRGFY-9180, engine #40654 / #40655 / #40656).
#
#   run.sh setup     open the two probe PRs, each touching .github/workflows/ci.yml
#   run.sh go        push the runner branch; its workflow merges both PRs with
#                    GITHUB_TOKEN and prints what GitHub answers
#   run.sh --reset   close every PR of the scenario and delete its branches
#
# GITHUB_TOKEN is a GitHub App installation token that can never hold the
# `workflows` permission, so it stands in for a Mergify installation whose
# owner has not accepted it. Mergify's own installation here has accepted it,
# which is why this probes GitHub directly instead of going through the queue.
#
# Both PRs target throwaway base branches, never `main`.
#
# Requires git + gh (authenticated as kozlek, with the `workflow` scope, to push
# workflow files). See README.md for the walkthrough.

set -euo pipefail

REPO="kozlek/sandbox"
RUNNER="wfp/runner"
BRANCHES=(wfp/base-reuse wfp/head-reuse wfp/base-3way wfp/head-3way "$RUNNER")
CI=.github/workflows/ci.yml

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

teardown() {
  echo "Closing scenario PRs and deleting branches..."
  for b in wfp/head-reuse wfp/head-3way; do
    gh pr close --repo "$REPO" "$b" >/dev/null 2>&1 || true
  done
  for b in "${BRANCHES[@]}"; do
    git push -q origin --delete "$b" >/dev/null 2>&1 || true
    git branch -D "$b" >/dev/null 2>&1 || true
  done
}

open_probe_pr() {  # $1 = base, $2 = head, $3 = title
  gh pr create --repo "$REPO" --base "$1" --head "$2" --title "$3" \
    --body "Probe for scenarios/workflows-permission-probe. Merged by the probe workflow, not by hand." >/dev/null
  echo "Opened $(gh pr view --repo "$REPO" "$2" --json url --jq .url)  ($3)"
}

case "${1:-}" in
  --reset)
    teardown
    echo "Done. main is untouched."
    ;;

  setup)
    require_clean_tree
    if git ls-remote --exit-code --heads origin wfp/base-reuse >/dev/null 2>&1; then
      echo "The probe branches already exist. Run '$0 --reset' first." >&2
      exit 1
    fi
    git fetch -q origin main

    # Case 1: the PR changes ci.yml and its base has not moved, so the merge
    # result is the PR's own tree: every workflow blob in it was already pushed.
    git checkout -q -B wfp/base-reuse origin/main
    push origin wfp/base-reuse
    git checkout -q -B wfp/head-reuse origin/main
    printf '\n# Probe: an edit on the pull request.\n' >> "$CI"
    git commit -q -am "ci: comment the workflow"
    push origin wfp/head-reuse
    open_probe_pr wfp/base-reuse wfp/head-reuse "probe: workflow change, base unchanged"

    # Case 2: the base edited ci.yml too, elsewhere in the file, so GitHub has
    # to 3-way merge it and the merged ci.yml is a blob nobody has pushed yet.
    git checkout -q -B wfp/base-3way origin/main
    { printf '# Probe: an edit on the base branch.\n'; cat "$CI"; } > "$CI.tmp" && mv "$CI.tmp" "$CI"
    git commit -q -am "ci: comment the workflow on the base"
    push origin wfp/base-3way
    git checkout -q -B wfp/head-3way origin/main
    printf '\n# Probe: an edit on the pull request.\n' >> "$CI"
    git commit -q -am "ci: comment the workflow"
    push origin wfp/head-3way
    open_probe_pr wfp/base-3way wfp/head-3way "probe: workflow change, base changed it too"

    git checkout -q main
    echo
    echo "Ready. When you want the probe to run: $0 go"
    ;;

  go)
    require_clean_tree
    git fetch -q origin main
    git checkout -q -B "$RUNNER" origin/main
    cat > .github/workflows/wfp-probe.yml <<'EOF'
name: workflows-permission probe
on:
  push:
    branches: [wfp/runner]
# GITHUB_TOKEN cannot be granted `workflows`: it is the app token without it.
permissions:
  contents: write
  pull-requests: write
jobs:
  probe:
    runs-on: ubuntu-latest
    env:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      REPO: ${{ github.repository }}
    steps:
      - name: "Case 1: the merge only reuses workflow content already pushed"
        run: |
          n=$(gh pr list -R "$REPO" --head wfp/head-reuse --json number --jq '.[0].number')
          echo "Squash-merging #$n with GITHUB_TOKEN..."
          gh api --include -X PUT "repos/$REPO/pulls/$n/merge" -f merge_method=squash 2>&1 | grep -E '^HTTP|"message"' || true
      - name: "Case 2: the merge writes a workflow file nobody pushed"
        run: |
          n=$(gh pr list -R "$REPO" --head wfp/head-3way --json number --jq '.[0].number')
          echo "Squash-merging #$n with GITHUB_TOKEN..."
          gh api --include -X PUT "repos/$REPO/pulls/$n/merge" -f merge_method=squash 2>&1 | grep -E '^HTTP|"message"' || true
EOF
    git add .github/workflows/wfp-probe.yml
    git commit -q -m "probe: merge both probe PRs with GITHUB_TOKEN"
    push -f origin "$RUNNER"
    git checkout -q main
    echo "Pushed ${RUNNER}. The run appears within a few seconds:"
    echo "  https://github.com/${REPO}/actions/workflows/wfp-probe.yml"
    ;;

  *)
    echo "usage: $0 setup | go | --reset" >&2
    exit 1
    ;;
esac
