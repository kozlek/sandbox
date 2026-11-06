# Test retry rescues a flaky test on `main`, and lets a real failure stand

Exercises test retry (MRGFY-8883): Test Engine → Configuration → Test Retry,
on the dashboard since 2026-10-30 (engine #49628, #49629, #50159, #50160).

**The pain.** A test that fails once in a while turns `main` red for nothing.
Someone reruns the job, or worse, gets used to ignoring red builds.

**What test retry does.** In a build of the default branch, the Mergify CI
plugin reruns a failing test until it passes, within limits the repository sets:
a budget (a share of the suite's expected duration, 5% by default, never under
4 s) and a cap on the retries of each test (5 by default). A test that passes
on a retry leaves the build green; one still failing after its retries fails it
as before. Tests Mergify knows as broken, and quarantined tests, are never
retried. Pull requests and merge-queue drafts never retry.

## How the bench stages it

- `.github/workflows/test-retry-demo.yml` runs `tests/` with pytest-mergify.
  It is a `workflow_dispatch` workflow, started on `main`, which the plugin
  counts as a build of the default branch.
- `test_card_payment_is_captured` calls a fake payment gateway whose first
  connection of the process times out. The plugin retries a test in the process
  that ran it, so only the first attempt fails: the flake is staged, and the
  retry that answers it is real.
- The `regression` act also ships a real bug in `refund`, so
  `test_refund_withholds_the_restocking_fee` fails on every attempt.
- `tests/conftest.py` keeps all of this out of the bench's `ci` check, which
  runs pytest from the repository root.

## Prerequisites

- The `MERGIFY_TOKEN` repository secret: an application key of the `kozlek`
  account with the CI scope.
- `TEST_RETRY_SETTINGS_FOR_ORGS` on for `kozlek` (3019422), or the dashboard
  hides the section. On since 2026-10-30.
- `ci_insights_quarantine` in kozlek's subscription features, or the plugin is
  told the repository has no test retry. Present.
- Test retry **off** on `kozlek/sandbox` before you start: Test Engine →
  Configuration → Test Retry.

## Walkthrough (about 5 minutes)

**Before the audience arrives**, with retry off:

```bash
scenarios/test-retry/run.sh flaky
```

Keep the link of that red run open: it is act 1.

1. **Main goes red for nothing.** Show the red run: one test of seven failed,
   and nothing is wrong with the code.

   ```
   test_checkout.py::test_card_payment_is_captured FAILED
   E           TimeoutError: the payment gateway did not answer within 2 s
   ========================= 1 failed, 6 passed in 0.32s ==========================
   ```

   Its Mergify CI block holds only the test run ID: retry is off.
2. **Turn it on.** Open the dashboard on `kozlek/sandbox` → Test Engine →
   Configuration → Test Retry. Flip the switch, confirm. Point at the defaults:
   5% retry budget, 5 retries per test, each marked as Mergify's default.
3. **Same build, green.**

   ```bash
   scenarios/test-retry/run.sh flaky
   ```

   About 20 s. The payment test now reads `RESCUED`, and the run is green:

   ```
   test_checkout.py::test_card_payment_is_captured RESCUED [100%]

   ================================== Mergify CI ==================================
   🔁 Test retry
   Test retry: 1 test failed, so Mergify retried it.
   It passed on a retry, so it does not fail this run.
   Passed on a retry:
     - scenarios/test-retry/tests/test_checkout.py::test_card_payment_is_captured (attempt 2)
   Test retry used 0.0 s of its 4.0 s budget.
   ========================= 6 passed, 1 rescued in 0.26s =========================
   ```

   The budget is 4 s, not 5% of the suite: a suite this small gets the floor.
4. **A real bug still fails.** Optionally lower "Retries per test" to 2 and
   save first, to show tuning.

   ```bash
   scenarios/test-retry/run.sh regression
   ```

   The payment test is rescued again, but the refund test fails on every
   attempt, and the run is red. Retry answers flakiness; it does not hide a
   regression.

   ```
   🔁 Test retry
   Test retry: 2 tests failed, so Mergify retried them.
   1 of them passed on a retry, so it does not fail this run.
   Passed on a retry:
     - scenarios/test-retry/tests/test_checkout.py::test_card_payment_is_captured (attempt 2)
   1 of them failed every attempt, so this run fails on it.
   Still failing:
     - scenarios/test-retry/tests/test_checkout.py::test_refund_withholds_the_restocking_fee (6 attempts)
   ==================== 1 failed, 5 passed, 1 rescued in 0.32s ====================
   ```

   Six attempts is the first run and the 5 default retries; with retries per
   test at 2, it is three.
5. **Who did what.** The repository's activity log names who turned test retry
   on and who changed its settings.

Don't click "How test retry works" in the section: its docs page,
`/test-engine/test-retry`, is not written yet.

**Afterwards**, switch test retry off on the dashboard, so the next run of the
demo starts from act 1.
