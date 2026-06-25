# Scenario: `skip_intermediate_results` in parallel mode (MRGFY-7620)

Demonstrates that `skip_intermediate_results` now works in `parallel` mode,
scoped to dependency chains: when a **child** car's CI passes, Mergify promotes
its not-yet-merged **ancestors** in the same scope chain — *even if an
ancestor's own car failed*.

**Config:** this scenario needs the repo's active `.mergify.yml` to be the
parallel + scopes + `skip_intermediate_results: true` config. That is already
the default on `main` (it's scenario #1), so no config swap is needed.

---

## Prerequisites (one makes or breaks it)

1. **Enable the org feature flag.** The parallel-mode skip is gated per org by
   `SKIP_INTERMEDIATE_RESULTS_PARALLEL_ENABLED_ORGS` (default **off**). If it's
   off for the `kozlek` org, the config is accepted but the skip **never
   fires** — you'd just see A's red car dequeue the chain. Add the `kozlek` org
   id to that flag via the internal per-account flag-override tooling and
   confirm it's live.
   - Gate logic: `engine/mergify_engine/queue/merge_train/train.py:1479`.
2. **Merge Queue product** on the `kozlek` account (scopes / parallel mode).
3. **Mergify GitHub App installed** on `kozlek/sandbox`.
4. **`gh` authenticated** as `kozlek`, and the repo already set up (top-level README).

---

## The three PRs

| PR | Branch | Scope | On its own | In the chain |
|----|--------|-------|-----------|--------------|
| **A** | `skip-demo/use-multiply` | `backend` | ❌ red — uses `multiply()`, undefined on `main` | parent of B |
| **B** | `skip-demo/add-multiply` | `backend` | ✅ defines `multiply()` | child — tested as **A+B**, ✅ green |
| **C** | `skip-demo/frontend-greeting` | `frontend` | ✅ | independent — runs in **parallel** |

Create them:

```bash
./scenarios/skip-intermediate-results/run.sh          # opens PRs A, B, C
./scenarios/skip-intermediate-results/run.sh --reset  # closes them + deletes branches
```

After it runs, expect PR A's `ci` check **red**, B and C **green**.

---

## Running it live

Open the **Merge Queue** dashboard for `kozlek/sandbox`, then queue the PRs **in
order** (autoqueue is on; the label drives it):

```bash
gh pr edit <A> --add-label queue   # backend
gh pr edit <B> --add-label queue   # backend  -> becomes A's child
gh pr edit <C> --add-label queue   # frontend -> independent parallel car
```

Narrate on the dashboard:

1. **Two scopes, in parallel.** Backend chain (`A`, then `A+B`) and the frontend
   car run their CI concurrently — that's `parallel` mode. (The draft PR bodies
   even include a Mermaid DAG.)
2. **The chain.** B is tested **on top of** A (`A+B`), not in isolation.
3. **The red ancestor.** A's own car turns red (`multiply()` undefined on
   `base+A`).
4. **The rescue.** B's `A+B` car turns green; `skip_intermediate_results`
   promotes A despite its red car, merges it, then B. C merges on its own car.
5. **Contrast.** Without the feature (or with the flag off), A's red car would
   abort the whole backend chain — the speedup
   [ssnielsen](https://app.plain.com/workspace/w_01HAMD2TEE3FEQ3GGQH0D4F5QQ/thread/th_01KTXFN8V28126JP9BZCPM5F67)
   would have lost switching from serial to parallel/scopes.

### Honest caveat (say it out loud)

A and B merge back-to-back in one engine tick, so for a few seconds `main` holds
`base+A` — red on its own. That transient, unvalidated intermediate is the
throughput-for-strictness trade `skip_intermediate_results` makes; it's why the
feature is opt-in.

---

## Reset

```bash
./scenarios/skip-intermediate-results/run.sh --reset
```

Closes the three PRs and deletes their branches. `main` is untouched, so the
sandbox is immediately ready for the next scenario.
