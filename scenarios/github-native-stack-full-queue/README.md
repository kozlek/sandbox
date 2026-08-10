# Full-stack queueing of a GitHub-native stack

Exercises `GITHUB_STACK_QUEUE_FOR_ORGS` (MRGFY-8468): every member of a
GitHub-native stack can queue, not just the effective bottom.

**What this scenario is actually for.** Not "does queueing work" — that has unit
and functional coverage. It is for the one thing no test and no production
observation can currently give us: **how GitHub's restack behaves when the
survivors are sitting in the merge queue.** With bottom-of-stack merging, only
the bottom is ever queued, so a restack has never hit a queued survivor. That
gap is what sizes two open engine decisions:

- how long the restack-trust window has to be (PR #38244 picked 15 minutes on
  observational data, and can likely be far tighter);
- whether making a trust mark cover exactly one head change (PR #38246) is a
  prerequisite or a follow-up.

## Prerequisites

- `GITHUB_STACK_QUEUE_FOR_ORGS` enabled for owner `3019422` (`kozlek`).
- The engine build deployed must contain the `feat(queue): queue every member of
  a GitHub-native stack` commit.
- The root `.mergify.yml` is this scenario's (see below). Restore the previous
  one with `git revert` / `git checkout <sha> -- .mergify.yml` when done.

## Why DRAFT checks, not INPLACE

The config carries **no `merge_queue:` block at all**, and that is what keeps
checks in DRAFT mode: `max_parallel_checks` defaults to 5, and
`should_run_checks_inplace` requires it to be exactly 1 (along with
`batch_size.max == 1`, `max_checks_retries == 0` and `mode == "serial"`), so the
default alone rules INPLACE out. Spelling `mode: parallel` explicitly would also
demand a `scopes.source` this scenario has no use for — the config is rejected
outright without one (`scopes.source must be configured … when using merge_queue
mode 'parallel'`).

INPLACE mode rebases the **user PR's own branch**, and GitHub refuses that for a
stack member — `Updating a stacked PR's branch via this endpoint is not
supported`. DRAFT mode builds its batch with `POST /merges`, which stopped being
fenced when stacks went to public preview, and never touches the member's
branch. Probed on this bench 2026-08-05: DRAFT queued a stack bottom and merged
it in 51s with the user branch untouched, while the same config in INPLACE mode
dequeued it in 25s on the update fence.

So: **INPLACE is the risky mode here, DRAFT is the safe one.** Note this is the
opposite of what #38245's commit message says ("first rollouts target
inplace-check configurations") — that sentence is wrong, and it is merged, so it
cannot be corrected in place. The inplace fence is what MRGFY-8448 / PR #38236
addresses with a GraphQL fallback; until that is deployed, do not run this
scenario in INPLACE mode.

## Walkthrough

```bash
scenarios/github-native-stack-full-queue/run.sh [N]     # N members, default 3
```

Opens an N-member chain (`gh-fq-1` on `main`, `gh-fq-2` on `gh-fq-1`, …) and makes
it a real native stack via `POST /repos/kozlek/sandbox/stacks`.

Every member appends a function to the **same** file (`backend/chain.py`). That is
deliberate — see "Results" below: with disjoint files GitHub only retargeted the
survivor and never rewrote its head, so the shape the trust marks exist for never
occurred. Overlapping content makes each survivor's branch genuinely diverge from
the post-landing base. The appends stay rebase-clean, because member *i*'s commit
adds its function after member *i-1*'s and the landed base already contains *i-1*'s.

Two gotchas that cost time if you rediscover them:

- `gh api ... -F "pull_requests[]=N"` — `-F` sends typed ints. Plain `-f` sends
  strings and the endpoint 422s.
- `POST /stacks` needs **at least 2** pull requests; single-PR stacks are no
  longer creatable.

Then:

1. **Queue both members**, bottom first:
   ```bash
   gh pr edit <bottom> --add-label queue
   gh pr edit <upper>  --add-label queue
   ```
   Entry is ordered by the injected native `[stack]` predecessor conditions, and
   a merely QUEUED predecessor satisfies them — so the bottom enters, then the
   upper, one evaluation per hop.

2. **Start the instrument** before releasing anything:
   ```bash
   scenarios/github-native-stack-full-queue/watch.sh <bottom> <upper>
   ```

3. **Confirm the upper is really embarked** (dashboard, or the `queued` label).
   This is the whole point — the survivor must be queued *before* the bottom
   lands, or the run measures nothing.

4. **The gate satisfies itself.** `merge_conditions: ["check-success=ci"]` binds
   to the repo's own `ci` workflow (`.github/workflows`, triggered on
   `pull_request`), which runs on the **draft batch PR** and passes in ~11s. So
   the bottom lands on its own — you do not post anything, but you do have only
   that ~11s of draft-build-plus-CI to get the upper embarked, which is why step 3
   matters. If a run keeps racing, force the gate under your own control by
   pointing `merge_conditions` at a context no workflow produces (e.g.
   `check-success=manual-gate`) and posting it yourself:
   ```bash
   gh api repos/kozlek/sandbox/statuses/<draft-head-sha> \
     -f state=success -f context=manual-gate
   ```

5. **Read the transitions.** `watch.sh` starts its clock at the first observed
   merge, so everything after that is "seconds after the landing". What to
   record:
   - `HEAD REWRIT` on the survivor → cascade-rebase shape, and how long after;
   - `RETARGET ... (head UNCHANGED)` → retarget-only shape, which never reaches
     the queue's synchronize detector at all;
   - whether multiple survivors move in one poll (batch-atomic) or separately.

6. **Then check what the queue did with it.** With PR #38244 not deployed there
   are no trust marks, so the expected outcome is that the survivor is
   **dequeued** (`PullRequestUpdated`) and re-admitted by its rules. Confirm in
   the event log / dashboard rather than inferring it.

## Results

### Run 1 — 2 members, disjoint files, squash (2026-08-10)

Full-stack queueing worked end to end, and **the restack never rewrote a head**.

| Time | Event |
|---|---|
| 08:32:24 | #235 embarked (train `main`, rule `autoqueue`, draft #238) |
| 08:32:31 | #236 embarked — **+7s**, train `main`, draft #239 |
| 08:33:42 | #236's draft checks passed — *before* the landing |
| 08:33:48 | #235 merged (squash, `329f0b9e63`) |
| +0s | #236 **RETARGET** `gh-fq-1` → `main`, **head UNCHANGED** |
| 08:34:10 | #236 merged (`7de051fa58`), 22s after the bottom |

Confirmed: members admitted bottom-up one hop per evaluation; same-stack members
keyed onto **one `main` train** even though #236's GitHub base was another PR's
branch; each got its own draft; landings sequenced via the effective-bottom
re-check. CI cost was N runs, not N(N+1)/2.

**Not** confirmed, and the reason run 2 exists: this was the benign
**retarget-only** shape, which never reaches the queue's synchronize detector. No
head rewrite means no trust mark was needed and #38244 would have been inert; and
#236's checks had already passed 6s before the landing, so the stale-checks window
was not exercised either. Notably #235 was *squash*-merged, so `main`'s tip was a
new commit while #236's branch still carried #235's original commit — the case
where a rebase looks most necessary — and GitHub still did not rebase.

## Teardown

```bash
scenarios/github-native-stack-full-queue/run.sh --reset
```

Closes the upper before the bottom on purpose: deleting the bottom's branch while
the upper still targets it closes the upper outright (`base_ref_deleted`), which
makes the next run's state confusing.

Restore the root `.mergify.yml` afterwards, and leave the repo's
`delete_branch_on_merge` setting as you found it — a previous campaign proved the
survivor's fate after a push-detection landing depends on that setting.
