# Scenario: stack child keeps squash-merged parents' commits (MRGFY-7739)

When a `mergify-cli` stack's parent PRs are **squash-merged**, the squash rewrites
each parent's commit on `main` **without** its `Change-Id` trailer. The child
PR's branch still carries the parents' **original** commits, and nothing rebases
them away — so the child displays **N commits instead of 1**, defeating the
one-commit-per-PR model that is the whole point of `mergify stack`.

This scenario reproduces that, and shows the kicker: the **stack auto-rebase
service does not clean it up**, because the polluted child is **content-clean
against `main`** (never `dirty`) and the service only acts on `dirty` PRs.

**Config:** this scenario needs `merge_method: squash`. `main` currently ships the
parallel + `skip_intermediate_results` config (scenario #1), so you must swap the
root config first:

```bash
cp scenarios/stack-squash-orphans/mergify.yml .mergify.yml
git add .mergify.yml && git commit -m "scenario: swap to squash queue" && git push
# ... run the scenario ...
git checkout origin/main -- .mergify.yml   # restore the active config when done
git commit -m "restore active config" && git push
```

---

## Prerequisites

1. **`mergify` CLI** installed and able to push stacks in this clone (run
   `mergify stack setup` once if you've never used stacks here).
2. **Merge Queue product** on the `kozlek` account, and the **Mergify app**
   installed on `kozlek/sandbox`.
3. **`gh` authenticated** as `kozlek`, repo set up (top-level README).
4. **Auto-rebase eligible for `kozlek`** — only needed for the *live proof* in
   step 4 that the service leaves the clean child alone. Both gates are already
   on (verified 2026-06-29):
   - rollout flag `STACK_AUTO_REBASE_ENABLED_ORGS` — `kozlek` has a non-excluded
     override (DB-backed `OrgFeatureFlag`, flipped in `/front/admin/feature-flags`);
   - `stacks_rebase` subscription feature present on the account.

---

## The stack

| PR | Module | On `main` after squash | Role |
|----|--------|------------------------|------|
| **P1** | `backend/orphan_a.py` | squash drops the `Change-Id` | bottom of stack |
| **P2** | `backend/orphan_b.py` | squash drops the `Change-Id` | child of P1 |
| **P3** | `backend/orphan_c.py` | not yet | **the PR we observe** (child of P2) |

Disjoint files → no conflicts → each parent squash-merges cleanly, and the child
stays mergeable (not `dirty`) — which is exactly the condition the bug needs.

Create / tear down:

```bash
./scenarios/stack-squash-orphans/run.sh          # opens P1, P2, P3
./scenarios/stack-squash-orphans/run.sh --reset  # closes them + deletes branches
```

---

## Running it live

### 1. Queue the parents only

```bash
gh pr edit <P1> <P2> --add-label queue
```

The queue squash-merges P1 → `main`, retargets P2, squash-merges P2 → `main`.
Leave **P3 unqueued** so you get a clean window to observe it.

### 2. Observe the bug on P3

```bash
gh pr view <P3> --json commits --jq '.commits | length'   # => 3  (should be 1)
gh pr view <P3> --json headRefOid                          # unchanged since the stack push
gh pr view <P3> --json mergeable,mergeStateStatus          # MERGEABLE / not DIRTY
```

P3 shows **3 commits** — `orphan_a`'s and `orphan_b`'s originals plus its own —
even though their content is already on `main` via the squashes. Its **diff** is
correct (just `orphan_c`), but its **commit list** is polluted, and its head was
never rewritten.

### 3. The speculative draft is polluted too

When P3 is queued, the queue's speculative draft is built on the polluted history
and re-applies the already-merged parent commits — wasted CI on a branch that
doesn't match the intended single-commit change (the `#1670` artifact in the
original report).

### 4. Live proof: the eligible auto-rebase service leaves P3 alone

Both gates are on for `kozlek` (see Prerequisites), yet P3 is never rebased —
because it never goes `dirty`.

```bash
# P3's numeric PR id (the ledger key — NOT the PR number):
PR_ID=$(gh api repos/kozlek/sandbox/pulls/<P3> --jq .id)

# Attempt ledger has NO row for P3 (run via the mergify-internal:prod-sql-query skill):
#   SELECT * FROM github_pull_request_stack_rebase_attempt WHERE pull_request_id = <PR_ID>;
#   => 0 rows
```

Also check Datadog `engine.stacks.auto_rebase.attempted{github_login:kozlek}` —
no `attempted` for P3 (at most a `mergeable_refresh_marked`).

**Why?** The service's candidate query gates on `mergeable IS FALSE AND
mergeable_state = 'dirty'` (`engine/mergify_engine/stacks/detection.py:710`). P3
is clean, so it's never selected. The rebaser's content/tree-equality skip
(`engine/mergify_engine/stacks/auto_rebase/rebaser.py:120`) *would* collapse the
squash-merged parents if it ran — but it never runs. The gap is the **trigger**,
not the rebaser.

### 5. Confirm `main` stays clean

```bash
gh pr edit <P3> --add-label queue        # let it merge
# its squash commit on main touches ONLY backend/orphan_c.py:
gh api repos/kozlek/sandbox/commits/<merge_sha> --jq '[.files[].filename]'
```

With `merge_method: squash`, the parents contribute no net diff, so `main` is
**not** polluted — this is a PR-state / speculative-test / review-churn problem,
not a `main`-history one.

### Sibling effect (MRGFY-7738)

Each parent merge retargets the child's base, and GitHub natively dismisses the
child's approvals ("The base branch was changed."). You'll see that here too — a
free demonstration of the sibling issue.

---

## Reset

```bash
./scenarios/stack-squash-orphans/run.sh --reset   # close PRs + delete branches
git checkout origin/main -- .mergify.yml          # restore the active config
git commit -m "restore active config" && git push
```

`main` is untouched by the scenario itself, so the bench is ready for the next one.
