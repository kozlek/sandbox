# Test retry saves a merge queue batch from a flaky test

Exercises test retry in the merge queue (MRGFY-12316): since the CI plugins'
2026.11.12, a failing test that the queue's target branch already knows is
retried in the runs the merge queue checks.

**The pain.** Three pull requests, each green on its own, are batched. A
flaky test fails the batch's run. The queue splits the batch, checks the
parts again, and every author waits on a test none of them touched.

**What test retry does in the queue.** In a run the merge queue checks, the CI
plugin retries a failing test the target branch knows, with the same budget
and per-test cap as on the default branch. A pass on a retry lets the run
pass, so the batch merges. A new test is never retried there: flaky detection
judges it, and a rescue could merge the flakiness its pull request brought.
Broken and quarantined tests are not retried either, and a pull request's own
run retries nothing. There is no setting beyond the switch that already turns
retry on for the default branch.

## How the bench stages it

- `trq/trunk` is a throwaway trunk `run.sh open` cuts from `main`. Pull
  requests into it run `.github/workflows/test-retry-queue-demo.yml`, the
  checkout tests of `scenarios/test-retry` under pytest-mergify, as the
  `checkout-tests` check.
- The `retry-demo` queue rule takes a pull request into `trq/trunk` labelled
  `trq-queue` once its own `checkout-tests` passes, batches three, and needs
  `checkout-tests` to pass on the batch's draft.
- The flake: the payment gateway's first connection of a process times out,
  in the queue's runs only. The workflow tells them by the draft's branch,
  `mergify/merge-queue/…`. Each pull request's own run is warm, so all three
  are green, and the batch's run meets the cold gateway. The retry that
  answers it is real.
- The known tests: `trq/trunk` is not a branch the repository tracks its tests
  on, so Mergify serves `main`'s, and `main` knows the payment test from the
  `test-retry` scenario's runs. A test `main` never ran would not be retried.
- Each pull request adds its own file under `copy/`, so the three never
  conflict.

## Prerequisites

- A trust policy of `kozlek` covering this repository's `pull_request` runs
  (Settings → OIDC): the job reaches Mergify with its GitHub ID token. Today's
  is "CI on every repository".
- `TEST_RETRY_SETTINGS_FOR_ORGS` on for `kozlek` (3019422), and
  `ci_insights_quarantine` in its subscription features: see `test-retry`.
- Test retry **on** for `kozlek/sandbox` for the live act (Test Engine →
  Configuration → Test Retry), and **off** for the "before" act.

## Walkthrough (about 5 minutes)

**Before the audience arrives**, with test retry off:

```bash
scenarios/test-retry-merge-queue/run.sh open
scenarios/test-retry-merge-queue/run.sh queue
```

The batch's run goes red on the payment test, and the queue splits the batch.
Keep the links of that red run and of the queue's page: they are act 1. Then
reset, switch test retry on, and open the three pull requests of the live
act, which takes about a minute:

```bash
scenarios/test-retry-merge-queue/run.sh --reset
scenarios/test-retry-merge-queue/run.sh open
```

1. **A flaky test fails a whole batch.** Show the red run of act 1 and the
   queue splitting the batch. Three pull requests, all green on their own,
   are held back by a test none of them touched.
2. **Nothing to configure.** Test Engine → Configuration → Test Retry is the
   switch you already turned on for `main`: it covers the merge queue too.
3. **Same batch, saved.**

   ```bash
   scenarios/test-retry-merge-queue/run.sh queue
   ```

   The three pull requests fill one batch, checked on one draft. Its run reads
   `RESCUED` for the payment test, and passes, and the three merge together.
4. **The queue says what retry saved.** Merge Queue → Activity: the batch's
   checks end carries a "1 test passed on a retry" badge. Statistics has a
   "Checks Saved by Retry" tile (Preview).

**Afterwards**, `run.sh --reset`.
