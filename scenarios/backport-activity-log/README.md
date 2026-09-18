# The activity log records a backport only when one happened

Exercises MRGFY-8674 and MRGFY-9158 (engine #40255, merged 2026-09-09, and
#40257, merged 2026-09-10).

**The bug.** The copy/backport processor sent its activity event from an
unconditional `finally`, so *every* outcome logged "Backported to X": a
conflict, a missing branch, a refused push, even a retry. The event has no
outcome field, and when no PR was created it named the *source* PR instead, so
a backport that never happened looked like a success in the customer's activity
log. In the 24 days to 2026-09-08, **284 of 3,904 backport events (7.3%)** were
backports that produced no pull request.

A second bug hid the real ones: `action.backport` / `action.copy` had no
outcome, so they rendered grey, and filtering the activity log on **Success**
returned no backports at all, including every one that worked.

## Prerequisites

None. No feature flag, and the fix is live for everyone. The scenario works on
throwaway branches (`bp/trunk` stands in for `main`), so it needs no queue and
no CI.

## Walkthrough (about 1 minute)

```bash
scenarios/backport-activity-log/run.sh
```

It opens a PR against `bp/trunk`, merges it, then comments:

```
@mergifyio backport bp/stable bp/legacy
```

`bp/stable` exists. `bp/legacy` does not, standing in for a branch deleted
after the backport rule was written.

1. On the PR, Mergify's command reply reports one success and one failure: a
   backport PR opened against `bp/stable`, and `bp/legacy` failed. That part
   was always right; the check run never lied.
2. Open the activity log:
   <https://dashboard.mergify.com/orgs/kozlek/repos/sandbox/activity-log>
   - **One** entry: "Backported to bp/stable", pointing at the new backport PR.
     Nothing for `bp/legacy`.
   - It is **green**, and it stays when you filter the outcome on **Success**.

**Before 2026-09-09**, the same run left *two* "Backported" entries. The
`bp/legacy` one pointed back at the merged PR itself and said
`conflicts: false`. Both were grey, and the Success filter hid them both.

Not covered here: the same fix for a failed `rebase`/`squash` (#40256). The
rebase that goes through that processor only runs for fork PRs, which this
bench does not have.

## Reset

```bash
scenarios/backport-activity-log/run.sh --reset
```

Closes the backport PR and deletes `bp/feature`, `bp/stable`, `bp/trunk` and
Mergify's `mergify/bp/bp/stable/*` branch. Run it before running the scenario
again. The activity-log entries stay: events are append-only.
