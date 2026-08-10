#!/usr/bin/env bash
#
# Measurement instrument for the restack mechanism.
#
# Polls each PR's head SHA, base ref and state, and prints ONE line per observed
# transition — nothing while things are stable. What we are measuring:
#
#   * when a member's head SHA is REWRITTEN (cascade-rebase shape), and how many
#     seconds after the landing that happened;
#   * when a member's base ref is RETARGETED without its head moving (the
#     retarget-only shape, which never reaches the queue's synchronize detector);
#   * whether survivors move together (batch-atomic) or one at a time.
#
#   watch.sh <pr> [<pr> ...]          poll until interrupted
#   POLL=1 watch.sh <pr> ...          override the 2s poll interval
#
# The clock starts at the first member observed to become merged, so the deltas
# printed after that are "seconds after the landing".

set -uo pipefail

REPO="${REPO:-kozlek/sandbox}"
POLL="${POLL:-2}"

if [ "$#" -lt 1 ]; then
  echo "usage: watch.sh <pr> [<pr> ...]" >&2
  exit 1
fi

declare -A last_sha last_base last_state
landed_at=""

stamp() {  # seconds since the landing, or wall clock before it
  if [ -n "${landed_at}" ]; then
    printf '+%4ds' "$(( $(date +%s) - landed_at ))"
  else
    date -u '+%H:%M:%SZ'
  fi
}

echo "watching ${*} in ${REPO} (poll ${POLL}s) — Ctrl-C to stop"

while :; do
  for pr in "$@"; do
    read -r sha base state < <(
      gh pr view "$pr" --repo "${REPO}" \
        --json headRefOid,baseRefName,state \
        --jq '"\(.headRefOid) \(.baseRefName) \(.state)"' 2>/dev/null
    ) || continue
    [ -z "${sha:-}" ] && continue

    if [ -z "${last_sha[$pr]:-}" ]; then
      printf '%s  #%-5s BASELINE      head=%s base=%s %s\n' \
        "$(stamp)" "$pr" "${sha:0:10}" "$base" "$state"
    else
      if [ "${last_state[$pr]}" != "$state" ]; then
        printf '%s  #%-5s STATE        %s -> %s\n' \
          "$(stamp)" "$pr" "${last_state[$pr]}" "$state"
        # First member to merge starts the clock.
        if [ "$state" = "MERGED" ] && [ -z "${landed_at}" ]; then
          landed_at="$(date +%s)"
          echo "                 ^^ landing observed — deltas below are seconds after it"
        fi
      fi
      if [ "${last_sha[$pr]}" != "$sha" ]; then
        printf '%s  #%-5s HEAD REWRIT  %s -> %s%s\n' \
          "$(stamp)" "$pr" "${last_sha[$pr]:0:10}" "${sha:0:10}" \
          "$([ "${last_base[$pr]}" != "$base" ] && echo '  (+retarget)')"
      fi
      if [ "${last_base[$pr]}" != "$base" ] && [ "${last_sha[$pr]}" = "$sha" ]; then
        printf '%s  #%-5s RETARGET     %s -> %s  (head UNCHANGED)\n' \
          "$(stamp)" "$pr" "${last_base[$pr]}" "$base"
      fi
    fi

    last_sha[$pr]="$sha"; last_base[$pr]="$base"; last_state[$pr]="$state"
  done
  sleep "${POLL}"
done
