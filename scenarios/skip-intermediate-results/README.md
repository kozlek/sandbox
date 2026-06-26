# Scenario: `skip_intermediate_results` in parallel mode (MRGFY-7620)

Demonstrates that `skip_intermediate_results` works in `parallel` mode, scoped to
dependency chains: when a **child** car's CI passes, Mergify promotes its
**still-pending ancestors** in the same scope chain — so an ancestor merges on
the child's strength instead of waiting for its own speculative check.

## How it actually works (read this — the obvious demo doesn't)

The skip promotes a chain member only while its own check is **pending**
(`WAITING_FOR_CI`). It does **not** rescue an ancestor whose check has
**definitively failed** — a failed car *parks the whole chain*. This is the
formally-verified `NoSkipWithFailure` invariant (`specs/MergeQueue.tla`), enforced
in `train.py` `_find_skippable_intermediate_promotions` via
`promotable_outcomes = {WAITING_FOR_CI, WAITING_FOR_MERGE, PREPARING, BATCH_SPLIT}`.

So the naive "ancestor red, child green → ancestor rescued" **does not work**: a
fast failure (e.g. a pytest collection error) goes definitive *before* the
`[A+B]` child car finishes, the chain parks, and the ancestor is dequeued.

This scenario makes it work by giving the ancestor a **slow** failure, so it
stays pending until the child's pass promotes it. The config description
("merge even if their own check fails") is therefore race-dependent: the child's
pass must win the race against the ancestor's failure becoming definitive.

---

## Prerequisites (one makes or breaks it)

1. **Enable the org feature flag.** The parallel-mode skip is gated per org by
   `SKIP_INTERMEDIATE_RESULTS_PARALLEL_ENABLED_ORGS` (default **off**). If it's
   off for the `kozlek` org, the config is accepted but the skip **never
   fires** — you'd just see A dequeue the chain. Add the `kozlek` org id to that
   flag via the internal per-account flag-override tooling and confirm it's live.
   - Gate: `engine/mergify_engine/queue/merge_train/train.py` →
     `_skip_intermediate_promotion_allowed()`.
2. **Merge Queue product** on the `kozlek` account (scopes / parallel mode). On a
   **public** repo this is free — only `*_private_repository` features are gated.
3. **Mergify GitHub App** granted access to `kozlek/sandbox`.
4. **`gh` authenticated** as `kozlek`, and the repo already set up (top-level README).

---

## The three PRs

| PR | Branch | Scope | On its own | In the chain |
|----|--------|-------|-----------|--------------|
| **A** | `skip-demo/use-multiply` | `backend` | uses `multiply()` (undefined on `main`) → **fails, but slowly** (~150s) | parent of B; stays `WAITING_FOR_CI` |
| **B** | `skip-demo/add-multiply` | `backend` | defines `multiply()` | child — tested as **A+B**, passes in ~30s |
| **C** | `skip-demo/frontend-greeting` | `frontend` | passes | independent — runs in **parallel** |

A's `backend/test_multiply.py` sleeps ~150s **only on the failing path** (missing
import); the `[A+B]` car has `multiply()` so it skips the sleep and passes fast.

```bash
./scenarios/skip-intermediate-results/run.sh          # opens PRs A, B, C
./scenarios/skip-intermediate-results/run.sh --reset  # closes them + deletes branches
```

---

## Running it live

Open the **Merge Queue** dashboard for `kozlek/sandbox`, then queue the PRs
**A→B→C within a second or two** — they must embark together so the cars coexist.
(A ~40s gap lets A's car resolve alone first and the chain never forms.)

```bash
gh pr edit <A> --add-label queue   # backend ancestor (slow-fail)
gh pr edit <B> --add-label queue   # backend child  → tested as A+B
gh pr edit <C> --add-label queue   # frontend       → parallel car
```

Narrate on the dashboard:

1. **Two scopes, in parallel.** Backend chain (`A`, then `A+B`) and the frontend
   car run their CI concurrently — that's `parallel` mode. (Draft PR bodies show
   a Mermaid DAG.)
2. **The chain.** B is tested **on top of** A (`A+B`), not in isolation.
3. **A is pending.** A's own car sits in `WAITING_FOR_CI` (sleeping ~150s); its
   check is doomed but not yet definitive.
4. **The skip.** B's `A+B` car passes in ~30s; `skip_intermediate_results`
   promotes A *while it's still pending* → A merges (~1 min after queue), then B.
   A's own check never completes — it's cancelled when A merges. C merges on its
   own car. Proof: A merged far faster than its ~2.5 min check could finish.
5. **`NoSkipWithFailure` corollary.** If A's check had failed *fast* (definitive
   before B passed), the chain would park and A would dequeue — the feature never
   skip-merges a definitively-failed batch.

### Honest caveat (say it out loud)

A (parent) merges before B (child), so for a moment `main` holds A's
`use multiply()` without B's `multiply()` definition — an unvalidated, broken
intermediate. That's the throughput-for-strictness trade `skip_intermediate_results`
makes; it's why the feature is opt-in.

---

## Reset

`run.sh --reset` closes the PRs and deletes their branches. Note that a
**successful** run merges A/B/C into `main` (changing `calculator.py`), so to
re-run from a clean state, also reset `main` to the base commit before the
scenario's merges.
