#!/usr/bin/env bash
#
# Submit GitHub's asynchronous Merge API for one pull request and poll to a
# terminal state, printing each observed status with a timestamp.
#
#   merge-async.sh <pr> [merge_method] [merge_action]
#       merge_method: squash (default) | merge | rebase
#       merge_action: default (server default) | direct_merge
#
# merge_action is NOT cosmetic. The engine hard-codes "direct_merge"
# (merge_helpers.py) because "default" silently hands the PR to GitHub's OWN
# merge queue on a queue-required branch. The open question this flag exists to
# probe: whether "direct_merge" also skips GitHub's stack-aware restack of the
# survivors, which would explain why a queue-driven landing left them merely
# retargeted (and conflicted) while a "default" landing rebased them clean.
#
# Semantics that matter for the landing-mode experiment: merge-async merges
# "every PR up to and including the one you request" -- so calling it on the TOP
# member lands the whole stack ATOMICALLY (individual commits per PR, in order),
# while calling it on the bottom lands only the bottom. Failure = nothing merged.
#
# Undocumented preview endpoint. 202 + a uuid, then poll; statuses are
# pending / merged / enqueued / failed. A duplicate submit returns 409 with the
# SAME uuid, which makes resubmission crash-safe.

set -uo pipefail

REPO="${REPO:-kozlek/sandbox}"
PR="${1:?usage: merge-async.sh <pr> [merge_method]}"
METHOD="${2:-squash}"
ACTION="${3:-}"

echo "$(date -u +%H:%M:%SZ)  submit  #${PR}  merge_method=${METHOD} merge_action=${ACTION:-<server default>}"
args=(-f "merge_method=${METHOD}")
[ -n "${ACTION}" ] && args+=(-f "merge_action=${ACTION}")
resp=$(gh api -X PUT "repos/${REPO}/pulls/${PR}/merge-async" "${args[@]}" 2>&1)
rc=$?
echo "  raw: ${resp}"
if [ $rc -ne 0 ]; then
  echo "$(date -u +%H:%M:%SZ)  SUBMIT FAILED  #${PR}"
  exit 1
fi

uuid=$(echo "$resp" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# the handle lives at details.uuid, NOT top level (verified live 2026-08-10)
if isinstance(d, dict):
    det = d.get("details") or {}
    print(det.get("uuid") or d.get("uuid") or "")
')

if [ -z "$uuid" ]; then
  echo "  no uuid in response -- treating the submit response as terminal (see raw above)"
  exit 0
fi

echo "  uuid=${uuid}"
prev=""
for _ in $(seq 1 60); do
  poll=$(gh api "repos/${REPO}/pulls/${PR}/merge-async/${uuid}" 2>&1)
  status=$(echo "$poll" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unparseable"); raise SystemExit
print(d.get("status") or d.get("state") or "unknown")
' 2>/dev/null)
  if [ "$status" != "$prev" ]; then
    echo "$(date -u +%H:%M:%SZ)  status  #${PR}  ${status}"
    prev="$status"
  fi
  case "$status" in
    merged|failed|enqueued)
      echo "  final: ${poll}"
      exit 0
      ;;
  esac
  sleep 3
done
echo "$(date -u +%H:%M:%SZ)  TIMED OUT polling #${PR} (last status: ${prev})"
