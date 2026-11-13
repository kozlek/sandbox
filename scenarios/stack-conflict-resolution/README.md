# `mergify stack push` keeps an approved stack when the queue resolves its conflict

Exercises mergify-ci-integrations #2322 (CLI 2026.11.6 and later): `stack push`
reads Mergify's conflict verdict before rebasing.

**The pain.** Your stack is approved. A teammate lands a change that adds a line
to the same changelog, and GitHub now says the bottom PR conflicts with trunk.
`mergify stack push` used to treat every conflict as one only a rebase settles.
You had to rebase the stack, resolve the changelog conflict by hand and
force-push, and the reviews went stale on every repository that dismisses them.

**What changed.** When the repository's `conflict_resolvers` settle that conflict
and the merge queue's draft is what lands the PR, Mergify says so in a
`Mergify Conflict Resolution` check run on the PR:
`Conflicts with <trunk>: Mergify resolves them when merging`. `stack push` reads
that check run, for the trunk tip it just fetched. If the stack is approved, it
skips the rebase and says why:

```
branch `cr/stack` rebase skipped: 2 PRs have approvals, and the merge queue resolves the bottom PR's conflicts (use --force-rebase to rebase anyway)
```

Without an approval, a bottom PR already in the queue stays there instead of
being rebased out of it.

## How the bench stages it

- `cr/trunk` is the stack's trunk, a throwaway copy of `main`. `run.sh trunk`
  lands the teammate's change there through the contents API, so `main` never
  moves.
- `conflict_resolvers` in the root `.mergify.yml` merges
  `scenarios/stack-conflict-resolution/CHANGELOG.md` with `union`, which keeps
  both sides' lines. Only that file, so no other scenario's conflicts change.
- The `conflict-demo` queue rule is the only one that can take a PR on
  `cr/trunk`, and it lands its draft (`merge-batch`). Mergify gives the verdict
  only when the queue's draft is what merges the PR. Elsewhere it would push a
  merge into the PR instead, which changes its head.
- The rule's queue conditions also ask for the `cr-land` label. Until
  `run.sh land` adds it, the PR matches no rule, and `auto_merge_conditions`
  does not queue it. Mergify gives a queued PR no verdict.
- `.github/workflows/approve.yml` approves each PR as `github-actions[bot]`,
  since you cannot approve your own.
- The stack lives in a worktree next to the bench,
  `../sandbox-stack-demo`. The live `mergify stack push` runs there.

## Prerequisites

- `RESOLVE_CONFLICTS_IN_PULL_REQUESTS_FOR_ORGS` on for `kozlek` (3019422).
  Without it Mergify writes no verdict, and the push rebases as before.
- "Allow GitHub Actions to create and approve pull requests" on in the
  repository's Actions settings, for `approve.yml`.
- The mergify CLI 2026.11.6 or later: `mergify --version`.

## Walkthrough (about 3 minutes)

**Before the audience arrives:**

```bash
scenarios/stack-conflict-resolution/run.sh setup   # approved two-PR stack
scenarios/stack-conflict-resolution/run.sh trunk   # the teammate's change lands
scenarios/stack-conflict-resolution/run.sh nit     # a review fix on the top PR
```

`trunk` waits until Mergify has written its verdict for the new trunk tip, so
the live push is not racing it.

1. **The stack is approved, and the bottom PR now conflicts.** Open the bottom
   PR: approved, and GitHub's banner says it has conflicts that must be
   resolved. Open its `Mergify Conflict Resolution` check: the changelog
   conflicts, and the repository's `union` resolver settles it when the queue
   merges.
2. **The push.** In the stack's worktree:

   ```bash
   cd ../sandbox-stack-demo
   mergify stack push
   ```

   The rebase is skipped, and the line says why. The top PR gets the review fix.
   The bottom PR keeps its head, so its approval and its CI run stand.
   Before 2026.11.6, this push rebased: you would be resolving
   `CHANGELOG.md` by hand right now.
3. **Optional: the queue resolves it.** `run.sh land` labels the bottom PR
   `cr-land`. The queue's draft merges it with `union` and lands it on
   `cr/trunk`, both changelog lines kept.

## Reset

```bash
scenarios/stack-conflict-resolution/run.sh --reset
```
