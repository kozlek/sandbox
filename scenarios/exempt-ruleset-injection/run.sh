#!/usr/bin/env bash
#
# Scenario: a repository ruleset whose Mergify bypass is `exempt` still has its
# rules injected as Mergify conditions (MRGFY-8588 / MRGFY-8537).
#
#   run.sh          arm the ruleset with a second required check, open the probe
#                   PR, label it `queue`
#   run.sh --release SHA
#                   post `probe-check=success` on SHA (the probe PR head, then
#                   the draft the queue opens) to release the injected condition
#   run.sh --reset  restore the ruleset to `ci` only, close the probe PR
#
# THE POINT. `.mergify.yml` on main asks for `check-success=ci` and nothing else.
# The ruleset asks for `ci` AND `probe-check`, and nothing in the repo ever
# produces `probe-check`. So the two outcomes are visibly different and cannot be
# confused:
#
#   injection ON  -> the PR never even enters the queue: `label=queue` matches but
#                    the injected `check-success = probe-check` does not.
#   injection OFF -> `label=queue` is the whole queue condition, `check-success=ci`
#                    is the whole merge condition, both green -> it merges.
#
# That is what makes `probe-check` worth the extra moving part over just reading
# `ci` out of the summary: `ci` is ALSO in `.mergify.yml`, so seeing it satisfied
# proves nothing about where the condition came from.
#
# Mergify is `exempt` on the ruleset, so GitHub itself never blocks the merge --
# only the injected condition does. `probe-check` is a plain commit status posted
# by hand (a check RUN would need an App); Mergify's `check-success` matches both.
#
# Requires git + gh authenticated as a repo admin (the ruleset PUT needs it).

set -euo pipefail

REPO="kozlek/sandbox"
BASE="main"
BRANCH="exempt-inject/probe"
RULESET=20739927          # `main-required-ci`
MERGIFY_APP_ID=10562      # Integration id of the Mergify GitHub App
PROBE_CHECK="probe-check"

cd "$(dirname "$0")/../.."

if [ ! -d .git ]; then
  echo "No git repo here. Set up the sandbox repo first (see top-level README)." >&2
  exit 1
fi

# The ruleset is rewritten wholesale: PUT /rulesets/{id} replaces every field, so
# both variants below have to carry the bypass actor and the ref conditions too.
put_ruleset() {  # $1 = JSON array of required status check contexts
  gh api --method PUT "repos/${REPO}/rulesets/${RULESET}" --input - >/dev/null <<JSON
{
  "name": "main-required-ci",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {"actor_id": ${MERGIFY_APP_ID}, "actor_type": "Integration", "bypass_mode": "exempt"}
  ],
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": false,
        "required_status_checks": $1
      }
    }
  ]
}
JSON
}

case "${1:-}" in
--reset)
  put_ruleset '[{"context": "ci"}]'
  echo "Ruleset back to \`ci\` only (bypass still exempt)."
  # Leaving probe-check armed would hold EVERY later PR out of the queue, so the
  # restore comes first and the PR cleanup is the best-effort part.
  gh pr close "${BRANCH}" --repo "${REPO}" --delete-branch >/dev/null 2>&1 || true
  git branch -D "${BRANCH}" >/dev/null 2>&1 || true
  echo "Probe PR closed. main is untouched."
  exit 0
  ;;
--release)
  SHA="${2:-}"
  if [ -z "${SHA}" ]; then
    echo "--release needs a SHA (the probe PR head, or the queue draft's head)." >&2
    exit 1
  fi
  gh api --method POST "repos/${REPO}/statuses/${SHA}" \
    -f state=success -f "context=${PROBE_CHECK}" \
    -f description="probe status posted by hand" --jq '.context + " -> " + .state'
  exit 0
  ;;
esac

put_ruleset '[{"context": "ci"}, {"context": "'"${PROBE_CHECK}"'"}]'
echo "Ruleset armed: requires \`ci\` + \`${PROBE_CHECK}\`, Mergify bypass \`exempt\`."

git fetch -q origin "${BASE}"
gh pr close "${BRANCH}" --repo "${REPO}" --delete-branch >/dev/null 2>&1 || true
git branch -D "${BRANCH}" >/dev/null 2>&1 || true
git checkout -q -B "${BRANCH}" "origin/${BASE}"

mkdir -p probe
printf 'Exempt-ruleset injection probe: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "probe/exempt-inject-$(date -u +%H%M%S).txt"
git add -A
git commit -q -m "exp(inject): probe exempt-ruleset condition injection"
git push -fq origin "${BRANCH}"

PR=$(gh pr create --repo "${REPO}" --base "${BASE}" --head "${BRANCH}" \
  --title "exp(inject): probe exempt-ruleset condition injection" \
  --body "Ruleset \`main-required-ci\` (Mergify bypass \`exempt\`) requires \`ci\` + \`${PROBE_CHECK}\`; \`.mergify.yml\` only requires \`check-success=ci\`. If the ruleset is still injected this PR cannot enter the queue." \
  | sed 's#.*/##')
gh pr edit "${PR}" --repo "${REPO}" --add-label queue >/dev/null
git checkout -q "${BASE}"

echo
echo "Probe PR #${PR} opened and labelled. Once \`ci\` is green, read:"
echo "  gh api repos/${REPO}/commits/${BRANCH}/check-runs \\"
echo "    --jq '.check_runs[] | select(.name==\"Mergify Merge Queue\") | .output.summary'"
echo
echo "Expected while injection is ON: 'Waiting for queue conditions to match',"
echo "with \`${PROBE_CHECK}\` unchecked under [🛡 GitHub repository ruleset rule]."
echo "Then release it (PR head first, then the draft the queue opens):"
echo "  scenarios/exempt-ruleset-injection/run.sh --release \$(gh pr view ${PR} --repo ${REPO} --json headRefOid --jq .headRefOid)"
echo "Finally: scenarios/exempt-ruleset-injection/run.sh --reset"
