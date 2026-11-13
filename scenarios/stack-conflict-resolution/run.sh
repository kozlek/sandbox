#!/usr/bin/env bash
#
# Scenario: `mergify stack push` keeps an approved stack as it is when the
# merge queue will resolve its conflict with trunk (mergify-ci-integrations
# #2322, CLI 2026.11.6).
#
#   run.sh setup     open an approved two-PR stack on the throwaway trunk
#                    `cr/trunk`, from its own worktree
#   run.sh trunk     land a changelog line on `cr/trunk` where the stack adds
#                    its own, and wait for Mergify's verdict on the bottom PR
#   run.sh verdict   wait for that verdict again, after a `@Mergifyio refresh`
#   run.sh nit       amend the top commit, so the live push has a change to push
#   run.sh land      label the bottom PR `cr-land`: the queue's draft resolves
#                    the conflict and lands it on `cr/trunk`
#   run.sh --reset   close the scenario's PRs, delete its branches and worktree
#
# The stack lives in a worktree next to the bench, ../sandbox-stack-demo
# (STACK_DIR overrides it): the live `mergify stack push` runs there. Nothing
# here touches `main`.
#
# Requires git, gh (authenticated as kozlek), the mergify CLI (2026.11.6 or
# later), and on `main`: the `conflict-demo` queue rule, `conflict_resolvers`
# and .github/workflows/approve.yml. See README.md for the walkthrough.

set -euo pipefail

REPO="kozlek/sandbox"
TRUNK="cr/trunk"
STACK_BRANCH="cr/stack"
LABEL="cr-land"
CHANGELOG="scenarios/stack-conflict-resolution/CHANGELOG.md"
CHECK_NAME="Mergify Conflict Resolution"
RESOLVES_SUFFIX=": Mergify resolves them when merging"
# What `mergify stack push` names the branch of each PR: <prefix>/cr/stack/<slug>.
STACK_HEAD_RE='(^|/)cr/stack/'

cd "$(dirname "$0")/../.."
BENCH="$(pwd)"
STACK_DIR="${STACK_DIR:-$(dirname "$BENCH")/sandbox-stack-demo}"

push() {  # git push, without GitHub's "Create a pull request" banner
  local out
  if ! out=$(git push -q "$@" 2>&1); then
    echo "$out" >&2
    return 1
  fi
}

stack_pulls() {  # the stack's open PRs, bottom first
  gh pr list --repo "$REPO" --state open --limit 100 \
    --json number,baseRefName,headRefName \
    --jq "[.[] | select(.headRefName | test(\"${STACK_HEAD_RE}\"))]
          | sort_by(.baseRefName != \"${TRUNK}\") | .[].number"
}

bottom_pull() {
  stack_pulls | head -n 1
}

require_stack() {
  if [ -z "$(bottom_pull)" ] || [ ! -d "$STACK_DIR" ]; then
    echo "No stack is open. Run '$0 setup' first." >&2
    exit 1
  fi
}

commit() {  # $1 = subject, $2 = body. A Change-Id is what maps a commit to its PR.
  git -C "$STACK_DIR" add -A
  git -C "$STACK_DIR" -c core.hooksPath=/dev/null commit -q \
    -m "$1" -m "$2" -m "Change-Id: I$(openssl rand -hex 20)"
}

approve() {  # $1 = PR number. Approves it as github-actions[bot] and waits.
  gh workflow run approve.yml --repo "$REPO" --ref main -f pull_request="$1" >/dev/null
  for _ in $(seq 60); do
    if [ "$(gh pr view --repo "$REPO" "$1" --json reviews \
      --jq '[.reviews[] | select(.state == "APPROVED")] | length')" -gt 0 ]; then
      return 0
    fi
    sleep 5
  done
  echo "#$1 is still not approved after 5 minutes: look at the approve workflow's runs." >&2
  return 1
}

verdict() {  # $1 = head SHA, $2 = trunk SHA. The verdict's title, empty until written.
  gh api -X GET "repos/${REPO}/commits/$1/check-runs" -f check_name="$CHECK_NAME" \
    --jq "[.check_runs[] | select(.status == \"completed\" and .external_id == \"$2\")][0].output.title // empty"
}

wait_for_verdict() {  # $1 = bottom PR, $2 = its head SHA, $3 = trunk SHA
  local title=""
  echo "Waiting for Mergify's verdict on #$1..."
  for _ in $(seq 36); do
    title=$(verdict "$2" "$3")
    [ -n "$title" ] && break
    sleep 5
  done
  if [ -z "$title" ]; then
    echo "No '${CHECK_NAME}' verdict for ${3:0:7} on #$1 after 3 minutes." >&2
    echo "Comment '@Mergifyio refresh' on it, then run '$0 verdict'." >&2
    exit 1
  fi
  echo "GitHub: #$1 is $(gh api "repos/${REPO}/pulls/$1" --jq .mergeable_state)."
  echo "Mergify (${CHECK_NAME}): ${title}"
  case "$title" in
    *"$RESOLVES_SUFFIX") ;;
    *) echo "That is not the verdict the push skips its rebase on." >&2; exit 1 ;;
  esac
  echo "Next, live: cd ${STACK_DIR} && mergify stack push   (or '$0 nit' first)"
}

teardown() {
  echo "Closing the scenario's PRs and deleting its branches..."
  # The queue's draft too: it targets the trunk.
  for n in $(gh pr list --repo "$REPO" --state open --limit 100 \
    --json number,baseRefName,headRefName \
    --jq ".[] | select((.headRefName | test(\"${STACK_HEAD_RE}\")) or .baseRefName == \"${TRUNK}\") | .number"); do
    gh pr close --repo "$REPO" "$n" >/dev/null 2>&1 || true
  done
  for b in $(git ls-remote --heads origin | awk '{print $2}' | sed 's#^refs/heads/##' \
    | grep -E "$STACK_HEAD_RE" || true) "$TRUNK"; do
    git push -q origin --delete "$b" >/dev/null 2>&1 || true
  done
  git worktree remove --force "$STACK_DIR" >/dev/null 2>&1 || true
  git worktree prune
  git branch -D "$STACK_BRANCH" >/dev/null 2>&1 || true
}

case "${1:-}" in
  --reset)
    teardown
    echo "Done. main is untouched."
    ;;

  setup)
    if [ -n "$(stack_pulls)" ] || [ -e "$STACK_DIR" ]; then
      echo "The scenario is already set up. Run '$0 --reset' first." >&2
      exit 1
    fi
    gh label create "$LABEL" --repo "$REPO" --color 0e8a16 \
      --description "Queue with the conflict-demo rule" --force >/dev/null

    git fetch -q origin main
    push -f origin "origin/main:refs/heads/${TRUNK}"
    git fetch -q origin "$TRUNK"
    git worktree add -q -B "$STACK_BRANCH" "$STACK_DIR" "origin/${TRUNK}"
    git -C "$STACK_DIR" branch -q --set-upstream-to="origin/${TRUNK}"

    cat > "$STACK_DIR/backend/slug.py" <<'EOF'
import re


def slugify(title: str) -> str:
    """Turn a title into a URL slug: "Hello, World!" -> "hello-world"."""
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
EOF
    echo '- Add `slugify()` to turn a title into a URL slug.' >> "$STACK_DIR/$CHANGELOG"
    commit "feat(slug): add slugify()" \
      "Blog permalinks need a URL slug built from the post's title."

    cat > "$STACK_DIR/backend/test_slug.py" <<'EOF'
from backend.slug import slugify


def test_slugify() -> None:
    assert slugify("Hello, World!") == "hello-world"
EOF
    commit "test(slug): cover slugify()" "Pin the slug of a title with punctuation."

    (cd "$STACK_DIR" && mergify stack push)

    # The bench's git config opens stack PRs as drafts, and Mergify gives a
    # draft no conflict verdict.
    for n in $(stack_pulls); do
      gh pr ready --repo "$REPO" "$n" >/dev/null 2>&1 || true
    done
    for n in $(stack_pulls); do
      approve "$n"
      echo "#$n approved by github-actions[bot]."
    done
    echo "Stack ready: https://github.com/${REPO}/pull/$(bottom_pull)"
    echo "Next: $0 trunk"
    ;;

  trunk)
    require_stack
    n=$(bottom_pull)
    head=$(gh pr view --repo "$REPO" "$n" --json headRefOid --jq .headRefOid)

    # A teammate's change lands on the trunk with its own changelog line, at
    # the very spot the stack adds its own: git calls that a conflict.
    git fetch -q origin "$TRUNK"
    content=$({ git show "origin/${TRUNK}:${CHANGELOG}"
      echo '- Make `divide()` raise a clear error on a zero divisor.'; } | base64 | tr -d '\n')
    tip=$(gh api -X PUT "repos/${REPO}/contents/${CHANGELOG}" \
      -f message="docs(changelog): note the divide() fix" \
      -f content="$content" \
      -f sha="$(git rev-parse "origin/${TRUNK}:${CHANGELOG}")" \
      -f branch="$TRUNK" --jq .commit.sha)
    echo "${TRUNK} is now ${tip:0:7}, with its own changelog line."
    wait_for_verdict "$n" "$head" "$tip"
    ;;

  verdict)
    require_stack
    n=$(bottom_pull)
    git fetch -q origin "$TRUNK"
    wait_for_verdict "$n" "$(gh pr view --repo "$REPO" "$n" --json headRefOid --jq .headRefOid)" \
      "$(git rev-parse "origin/${TRUNK}")"
    ;;

  nit)
    require_stack
    cat >> "$STACK_DIR/backend/test_slug.py" <<'EOF'


def test_slugify_collapses_runs_of_punctuation() -> None:
    assert slugify("Stacks -- now with approvals!") == "stacks-now-with-approvals"
EOF
    git -C "$STACK_DIR" -c core.hooksPath=/dev/null commit -q -a --amend --no-edit
    echo "Amended the top commit with a second test, as a review would ask."
    echo "Next, live: cd ${STACK_DIR} && mergify stack push"
    ;;

  land)
    require_stack
    n=$(bottom_pull)
    gh pr edit --repo "$REPO" "$n" --add-label "$LABEL" >/dev/null
    echo "#${n} carries '${LABEL}': the conflict-demo rule queues it. Waiting for it to land..."
    state=""
    for _ in $(seq 60); do
      state=$(gh pr view --repo "$REPO" "$n" --json state --jq .state)
      [ "$state" = MERGED ] && break
      sleep 10
    done
    if [ "$state" != MERGED ]; then
      echo "#${n} has not landed after 10 minutes: look at its Mergify Merge Queue check." >&2
      exit 1
    fi
    git fetch -q origin "$TRUNK"
    echo "#${n} landed. ${CHANGELOG} on ${TRUNK}:"
    git show "origin/${TRUNK}:${CHANGELOG}"
    ;;

  *)
    echo "usage: $0 setup | trunk | verdict | nit | land | --reset" >&2
    exit 1
    ;;
esac
