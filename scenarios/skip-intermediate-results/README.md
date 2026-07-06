# Scenario: `skip_intermediate_results` in parallel mode (MRGFY-7620)

Demonstrates that `skip_intermediate_results` works in `parallel` mode, scoped to
dependency chains: when a **child** car's CI passes, Mergify promotes its
**still-pending ancestor** in the same scope chain — so the ancestor merges on the
child's strength instead of waiting for (or being blocked by) its own speculative
check. A second scope runs a car **in parallel** so the *parallel* part is visible.

Three PRs, three cars (only the ancestor sleeps, so it's cheap):

- **A** — `backend`, the ancestor; fails slowly on its own.
- **B** — `backend`, the fix; queued **last**, its `[A+B]` car promotes A.
- **F** — `frontend`, an independent car that runs **concurrently** with the
  backend chain (this is what makes it visibly *parallel*, not serial).

## How it actually works (read this — the obvious demo doesn't)

The skip promotes a chain member only while its own check is **pending**
(`WAITING_FOR_CI`). It does **not** rescue an ancestor whose check has
**definitively failed** — a failed car *parks the whole chain*. This is the
formally-verified `NoSkipWithFailure` invariant (`specs/MergeQueue.tla`), enforced
in `_find_skippable_intermediate_promotions`
(`engine/mergify_engine/queue/merge_queue/merge_queue.py`) via
`promotable_outcomes = {WAITING_FOR_CI, WAITING_FOR_MERGE, PREPARING, BATCH_SPLIT}`.

So the naive "ancestor red, child green → ancestor rescued" **does not work**: a
*fast* failure (e.g. a pytest collection error) goes definitive *before* the child
car finishes, the chain parks, and the ancestor is dequeued. This scenario makes
it work by giving A a **slow** failure — its test sleeps ~300s **only on the
failing path** (missing import) — so A stays pending until B's car passes.

---

## Prerequisites (one makes or breaks it)

1. **Enable the org feature flag.** The parallel-mode skip is gated per org by
   `SKIP_INTERMEDIATE_RESULTS_PARALLEL_ENABLED_ORGS` (default **off**). If it's off
   for the `kozlek` org, the config is accepted but the skip **never fires** (you'd
   just see A dequeue). Add the `kozlek` org id via the internal per-account
   flag-override tooling and confirm it's live.
   - Gate: `_skip_intermediate_promotion_allowed()` in
     `engine/mergify_engine/queue/merge_queue/merge_queue.py`.
2. **Merge Queue product** on the `kozlek` account. On a **public** repo it's free
   — only `*_private_repository` features are gated.
3. **Mergify GitHub App** granted access to `kozlek/sandbox`.
4. **`gh` authenticated** as `kozlek`, and the repo set up (top-level README).

---

## The PRs

| PR | Branch | Scope | On its own | In the run |
|----|--------|-------|-----------|------------|
| **A** | `skip-demo/use-multiply` | `backend` | uses `multiply()` (undefined on `main`) → **fails slowly** (~300s) | ancestor; stays `WAITING_FOR_CI` |
| **B** | `skip-demo/add-multiply` | `backend` | defines `multiply()` | queued **last**; car is `[A+B]`, passes fast, promotes A |
| **F** | `skip-demo/frontend-greeting` | `frontend` | passes | independent car, runs **in parallel** with the backend chain |

3 cars, well under `max_parallel_checks: 5`. Only A's car sleeps (~300s on the
missing import); B's `[A+B]` car has `multiply()` so it skips the sleep and passes
fast; F's car is unrelated and merges on its own.

```bash
./scenarios/skip-intermediate-results/run.sh          # opens A, B, F
./scenarios/skip-intermediate-results/run.sh --reset  # closes them + deletes branches
```

---

## Running it live — the reliable queue order

⚠️ **Order matters, and labeling everything at once is a coin-flip.** The
parent/child chain is decided by `queued_at`, and Mergify processes
near-simultaneous label webhooks in **nondeterministic order**. If B embarks
before A, it becomes A's *parent* — A gets tested *with* the fix, passes on its
own, and **no skip fires**. So:

1. Label **A** and **F** (F is a different scope, order-independent):
   ```bash
   R=kozlek/sandbox
   gh pr edit "$(gh pr list -R $R -H skip-demo/use-multiply     --json number -q '.[0].number')" -R $R --add-label queue
   gh pr edit "$(gh pr list -R $R -H skip-demo/frontend-greeting --json number -q '.[0].number')" -R $R --add-label queue
   ```
2. **Wait** until A has embarked (it gets Mergify's `queued` label).
3. **Then** label **B** last:
   ```bash
   gh pr edit "$(gh pr list -R $R -H skip-demo/add-multiply --json number -q '.[0].number')" -R $R --add-label queue
   ```

On the dashboard you'll see **F's frontend car running alongside the backend
chain** (parallel mode). When B's `[A+B]` car turns green, A merges *"with no time
running CI."*

---

## Seeing the skip on the dashboard

- **The badge (live, transient).** A's promoted batch shows an indigo **"Intermediate
  skipped"** pill (⏭ icon; tooltip *"Merged without waiting for its own CI — a later
  batch that includes these changes passed"*) —
  `dashboard/src/modules/queues/merge-queue/components/Batch/SkipIntermediateBadge.tsx`,
  driven by the API's `intermediate_results_skipped`. It shows on the **batch
  header** and in the **Batch Peek drawer**, from promotion until the batch merges
  out (a few seconds). Since there's just one badge, **open the Batch Peek drawer on
  A's batch the moment B's car goes green** to hold it in view — that's the reliable
  way to catch it (no need for extra ancestors/jobs).
- **The receipt (persistent).** A's Merge Queue status comment reads *"spent … in
  the queue, **with no time running CI**"*, and its `check-success=ci` condition
  stays unticked — merged without its own check.
- **The event log (persistent).** The merge event carries an
  `INTERMEDIATE_RESULTS_SKIPPED` reason:
  `dashboard.mergify.com/event-logs?pullRequestNumber=<N>&login=kozlek&repository=sandbox`.

---

## Reset

`run.sh --reset` closes the PRs and deletes their branches. A **successful** run
merges A/B/F into `main` (changing `calculator.py`), so to re-run from a clean
state, also reset `main` to the base commit before those merges
(`git push --force origin main` to the pre-run SHA).
