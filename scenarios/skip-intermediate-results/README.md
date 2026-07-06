# Scenario: `skip_intermediate_results` in parallel mode (MRGFY-7620)

Demonstrates that `skip_intermediate_results` works in `parallel` mode, scoped to
dependency chains: when a **child** car's CI passes, Mergify promotes its
**still-pending ancestors** in the same scope chain — so an ancestor merges on the
child's strength instead of waiting for (or being blocked by) its own speculative
check.

This scenario uses a **4-ancestor chain** so the effect is *visible*: four
ancestors get promoted at once, flashing four dashboard badges together (see
[Seeing the skip](#seeing-the-skip-on-the-dashboard)).

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
it work by giving each ancestor a **slow** failure — its test sleeps ~300s **only
on the failing path** (missing import) — so the ancestor stays pending until the
fix car passes and promotes it.

---

## Prerequisites (one makes or breaks it)

1. **Enable the org feature flag.** The parallel-mode skip is gated per org by
   `SKIP_INTERMEDIATE_RESULTS_PARALLEL_ENABLED_ORGS` (default **off**). If it's off
   for the `kozlek` org, the config is accepted but the skip **never fires** (you'd
   just see the ancestors dequeue). Add the `kozlek` org id via the internal
   per-account flag-override tooling and confirm it's live.
   - Gate: `_skip_intermediate_promotion_allowed()` in
     `engine/mergify_engine/queue/merge_queue/merge_queue.py`.
2. **Merge Queue product** on the `kozlek` account. On a **public** repo it's free
   — only `*_private_repository` features are gated.
3. **Mergify GitHub App** granted access to `kozlek/sandbox`.
4. **`gh` authenticated** as `kozlek`, and the repo set up (top-level README).

---

## The PRs (4 ancestors + 1 fix)

All `backend` scope, so they form one chain. `run.sh` creates:

| PR | Branch | On its own | In the chain |
|----|--------|-----------|--------------|
| **A1–A4** | `skip-demo/use-op1` … `use-op4` | each uses `opN()` (undefined on `main`) → **fails slowly** (~300s) | ancestors; each stays `WAITING_FOR_CI` |
| **B** | `skip-demo/add-ops` | defines `op1`…`op4` | queued **last**; its car is `[A1..A4 + B]`, passes fast, promotes all four |

5 cars = the `max_parallel_checks: 5` cap, so all run concurrently. Each ancestor's
`backend/test_opN.py` sleeps ~300s **only** on the missing-import path; B's car has
every op so it skips the sleeps and passes in ~30–60s.

```bash
./scenarios/skip-intermediate-results/run.sh          # opens the 5 PRs
./scenarios/skip-intermediate-results/run.sh --reset  # closes them + deletes branches
```

---

## Running it live — the reliable queue order

⚠️ **Order matters, and labeling everything at once is a coin-flip.** The
parent/child chain is decided by `queued_at`, and Mergify processes
near-simultaneous label webhooks in **nondeterministic order**. If the fix embarks
before an ancestor, it becomes that ancestor's *parent* — the ancestor gets tested
*with* the fix, passes on its own, and **no skip fires**. So:

1. Label all four ancestors:
   ```bash
   R=kozlek/sandbox
   for op in op1 op2 op3 op4; do
     gh pr edit "$(gh pr list -R $R -H skip-demo/use-$op --json number -q '.[0].number')" -R $R --add-label queue
   done
   ```
2. **Wait** until all four have embarked (each gets Mergify's `queued` label).
3. **Then** label the fix last:
   ```bash
   gh pr edit "$(gh pr list -R $R -H skip-demo/add-ops --json number -q '.[0].number')" -R $R --add-label queue
   ```

When B's `[A1..A4 + B]` car turns green, all four still-pending ancestors are
promoted at once and merge in sequence — each *"with no time running CI."*

---

## Seeing the skip on the dashboard

- **The badge (live, transient).** A promoted batch shows an indigo **"Intermediate
  skipped"** pill (⏭ icon; tooltip *"Merged without waiting for its own CI — a later
  batch that includes these changes passed"*) —
  `dashboard/src/modules/queues/merge-queue/components/Batch/SkipIntermediateBadge.tsx`,
  driven by the API's `intermediate_results_skipped`. It shows on the **batch
  header** and in the **Batch Peek drawer**, from promotion until the batch merges
  out (a few seconds). The 4-ancestor chain gives you four at once; to *hold* the
  view, open the **Batch Peek drawer** on an ancestor the moment B's car goes green.
- **The receipt (persistent).** Each merged ancestor's Merge Queue status comment
  reads *"spent … in the queue, **with no time running CI**"*, and its
  `check-success=ci` condition stays unticked — merged without its own check.
- **The event log (persistent).** The merge event carries an
  `INTERMEDIATE_RESULTS_SKIPPED` reason:
  `dashboard.mergify.com/event-logs?pullRequestNumber=<N>&login=kozlek&repository=sandbox`.

---

## Reset

`run.sh --reset` closes the PRs and deletes their branches. A **successful** run
merges the ancestors + fix into `main` (changing `calculator.py`), so to re-run
from a clean state, also reset `main` to the base commit before those merges
(`git push --force origin main` to the pre-run SHA).
