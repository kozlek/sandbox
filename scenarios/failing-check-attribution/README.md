# The merge queue names the check that failed

Exercises MRGFY-8607 (engine #38516, #38517, #38518, all merged 2026-09-08).

**The bug.** When a pull request left the queue with "checks failed", the
"Failing checks" list could name a check that was *still running*, while the
check that actually broke the conditions was never shown. A customer opened
the named check, found it green 26 s after the dequeue, and had no way to reach
the real cause. In the week before the fix, 152 of 2,943 checks-failed dequeues
(5.2%, 63 repositories) named no failing check and at least one pending one.

**How it happened.** The queue conditions are evaluated on the *user* PR, while
the merge conditions run on the queue's *draft* PR. When a check on the user PR
failed, the dequeue reason carried no check name, so the report fell back to
the draft's check snapshot, where the only non-green check was the one still
running.

## Prerequisites

- The `checks-demo` queue rule in the root `.mergify.yml` (on `main` since this
  scenario landed). It needs `security-scan` green on the PR to queue it, and
  `ci` green on the draft to merge.
- Nothing else: no feature flag, and the fix is live for everyone.

## Walkthrough (about 3 minutes)

```bash
scenarios/failing-check-attribution/run.sh start
```

Opens a PR against the throwaway branch `fca/trunk`, reports `security-scan` as
green on it, and adds the `checks-demo` label. The PR adds a test that sleeps
for 4 minutes, so `ci` stays running for the whole demo.

1. Show the PR entering the queue, then the draft PR appearing with `ci`
   running on it (about 20 s).
2. *"Now the security scanner reports late, while the queue is still testing."*

   ```bash
   scenarios/failing-check-attribution/run.sh fail-scan
   ```

   The script refuses to run before the draft exists: dequeuing earlier shows
   nothing.
3. Within a few seconds Mergify dequeues the PR. Show its merge-queue comment:

   ```
   ## Reason

   The merge conditions cannot be satisfied due to failing checks

   - `security-scan`
   ```

   And **no** "Failing checks" list naming `ci`, which is still running.

**Before 2026-09-08**, the same dequeue read:

```
## Reason

The merge conditions cannot be satisfied due to failing checks

Failing checks:
- 🟠 ci
```

It named `ci`, which went on to pass, and never mentioned `security-scan`.

### Known issue that shows up in this demo

Rehearsed 2026-09-18 (kozlek/sandbox#323): the reason lists **two** checks:

```
- `Mergify Merge Protections`
- `security-scan`
```

`Mergify Merge Protections` did not fail. It is `neutral` ("No merge
protections matched"). Mergify injects it as a gate that passes on
`success`, `neutral` *or* `skipped`, but the failing-check finder reads each
branch of that `or` on its own. It sees `check-success` false, and names the
check. This is the "or-group" gap left open by MRGFY-8607. The same bug already
affected the merge queue's own path; the cancel path now inherits it.

In production, since 2026-09-08 about 100–150 checks-failed dequeues a day
(1 in 6, 86 orgs) name `Mergify Merge Protections`. Before, it was 60–100 a
day, with another 100–150 a day naming no check at all.

Either say it out loud ("the next fix is already visible here"), or stage around
it with a merge protection that *succeeds* on this PR. The check is then
`success`, and the `or` is decided without it:

```yaml
merge_protections:
  - name: checks-demo
    if:
      - base = fca/trunk
    success_conditions:
      - label = checks-demo
```

Also slightly off in the same comment: its timeline says "❌ Checks failed · on
draft #N", though the check that failed was on the PR, not the draft.

### Optional second beat (#38516)

The same list used to print a condition's operand as if it were a check name.
With `#check-failure=0` in the merge conditions, customers were told the
failing check was called `` `0` ``. A regex condition such as
`check-success~=^ci-` printed the regex. Neither is staged here. It's a one-line
anecdote to tell, not something to demo.

## Reset

```bash
scenarios/failing-check-attribution/run.sh --reset
```

Closes the draft and the PR, and deletes `fca/change` and `fca/trunk`. Run it
before `start` again: `start` refuses while a scenario PR is open.
