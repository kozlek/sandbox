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
