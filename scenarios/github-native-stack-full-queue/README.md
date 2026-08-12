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

Every member appends a function to the **same** file (`backend/chain_<TAG>.py`). That
is deliberate — see "Results" below. Overlapping content makes each survivor's branch
genuinely diverge from the post-landing base, which is what exposes whether GitHub
rebases the survivor or merely retargets it.

It does **not** stay rebase-clean, and an earlier version of this file claimed it
did. That claim assumed a rebase happens. When GitHub does not rebase, the survivor
still carries the landed member's *original* commit while the base carries the same
change as a *new* squash commit — merge-base predates both, so it is an add/add on the
same region and it **conflicts**. Run 1 escaped only because its duplicated content
was byte-identical, which git resolves silently.

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

**Not** confirmed, and the reason the later runs exist: this was the
**retarget-only** shape, which never reaches the queue's synchronize detector. No
head rewrite means no trust mark was needed and #38244 would have been inert.

### The campaign, and what discriminates the two shapes (2026-08-10)

Same 3-member same-file fixture throughout; only the landing method varied.

| Test | Landed by | Queued survivors | `head_ref_force_pushed` | Survivor |
|---|---|---|---|---|
| A | `kozlek` user token, server-default `merge_action` | no | ✅ +2s | **clean** |
| B | `kozlek`, one call on the **top** member | — | n/a (no survivors) | all 3 merged in **1s** |
| C | `kozlek` user token, `merge_action=direct_merge` | no | ✅ +2s | **clean** |
| D | `mergify[bot]` via the merge queue | **yes** | ❌ absent | **`dirty`** |
| E | `mergify[bot]` via the merge queue | **no** | ❌ absent | **`dirty`** |

**A healthy landing is TWO GitHub actions**, visible in the survivor's issue
timeline: `automatic_base_change_succeeded` (+1s), then `head_ref_force_pushed`
(~2s later) which is the rebase. The cascade is batch-atomic — in test C *both*
survivors' heads moved in the same 2s poll, including the one whose base had not
changed.

**The discriminator is who merges.** A user token gets the rebase; the
`mergify[bot]` installation token does not — GitHub retargets and stops, leaving the
survivor carrying the landed member's original commit, hence `dirty`. Two hypotheses
were tested and **refuted**: `merge_action` (test C used the engine's `direct_merge`
and still rebased) and queue involvement (test E had no queued survivors and no draft
PRs and still failed to rebase). `automatic_base_change_succeeded` is GitHub's own
event and its `actor` is merely whoever merged — it appears in every case, so it is
not the signal; the *absence of the force-push* is.

**Measured cascade-rebase latency: 3–4s** (bounded by a 2s poll). PR #38244 sizes its
trust window at 15 minutes — ~225x that.

**Consequences.**

- On the App path GitHub produces **no head rewrite at all**, so the synchronize
  detector never fires and #38244 has nothing to absorb. Its premise does not hold
  for the path customers actually use. Caveat kept deliberately: production SQL did
  record rewrites 6.6–13.2s after landings, and users merge the large majority of
  native-stack members in production, so those rewrites are plausibly user landings
  — worth confirming before treating this as universal, and worth re-testing whenever
  GitHub changes preview behaviour, since the asymmetry looks like a bug not a
  contract.
- The **real** blocker for full-stack queueing is the missing rebase: the survivor
  conflicts, is dequeued, and burns a CI run. Reproduced 2/2 on the Mergify path.
- **Atomic landing eliminates it** (test B): one `merge-async` call on the top member
  lands every member below it, so there are no survivors, no restack, and no conflict.
  That item is filed under "known limits" in #38245's merged message; on this evidence
  it is a prerequisite for stacks deeper than 2, not a nicety.

### Test F — what one merge-async call writes as commit messages (2026-08-11)

Sizes the "batch the stack, land it with one merge-async" design: does a single
call preserve the engine's per-PR commit message? Fresh 3-member stack
(#272 → #273 → #274), one `merge_method=squash merge_action=direct_merge` call on
the **top** member, carrying an explicit `commit_title`/`commit_message` that
matched no PR.

Merged in **~3s**, all three, bottom-first, no survivors.

| Landed commit | PR | Subject | Body |
|---|---|---|---|
| `5e54f29` | #272 (bottom) | `exp(fq): member 1 of 3 (#272)` | *(repo default)* |
| `4a3304c` | #273 | `exp(fq): member 2 of 3 (#273)` | *(repo default)* |
| `0accedb` | #274 (**requested**) | `CUSTOM-TITLE-FROM-PAYLOAD (#999)` | the payload's |

**The payload's message applies ONLY to the requested pull request.** Every
member below it gets GitHub's repo-level rendering
(`squash_merge_commit_title=COMMIT_OR_PR_TITLE`, `…_message=COMMIT_MESSAGES`),
per PR — each with its own number, so they are not clones of the top.

That is a narrower problem than it first looks, because on **default config the
engine sends no message at all**: `commit_message_renderer.resolve` returns
`(None, None)` when neither `commit_message_template` nor
`commit_message_format` is set (and no in-body `# Commit Message` section), and
the merge helper then omits both fields so GitHub's repo default renders — the
same rendering the members below just got. So a single call is **byte-identical
to N individual merges on default config**; the divergence is confined to
configs that set a template/format, and there only for the N-1 members below
the requested one.

Second unknown, also answered: **each PR carries its own correct
`merge_commit_sha`** (and its own `merged_at`, 1s apart) even though the result
object reports only the top's `details.sha`. Per-PR bookkeeping therefore just
needs a re-read of each member, not a derivation.

### Run 2 — 3 members, same file, squash, under an EXEMPT ruleset (2026-08-12)

First run with a repository ruleset in play: `main-required-ci` (id `20739927`),
`enforcement: active` on `~DEFAULT_BRANCH`, one rule `required_status_checks`
(context `ci`), and the Mergify app (Integration `10562`) as a bypass actor in
**`exempt`** mode — the only mode GitHub's merge-async honours (MRGFY-8537).

Stack #280 = #277 → #278 → #279, fixture `backend/chain_101506.py`.

| Time (UTC) | Event |
|---|---|
| 10:15:57 | all three labelled `queue` |
| 10:16 | all three admitted to **one `main` train**; drafts #281 (`#277`), #282 (`#277+#278`), #283 (all three) |
| 10:18:36 | **#277 merged** via merge-async (`1334a082bc`) — the exempt ruleset did **not** block it |
| +0s | #278 **RETARGET** `gh-fq-1` → `main`, **head UNCHANGED** — no force-push, no rebase |
| +18s | #278 `CONFLICTING/DIRTY` |
| 10:21 | **both survivors dequeued** — #278 `Queue conditions are not satisfied: -conflict`; #279 `conflict with base branch` |
| 10:26 | settled: both carry `dequeued`, no drafts open, **no autoqueue re-admission** |

**Net: 1 of 3 landed.** The stack is stuck and the survivors need a manual rebase.

Two things this run establishes that the earlier campaign could not:

- **The exempt bypass works end to end.** With an active ruleset on `main`, the
  stack bottom merged through merge-async with no refusal and no
  `Cannot update this protected ref.` — MRGFY-8590's pre-check stayed silent,
  which is the correct outcome for `exempt`.
- **Condition injection is live and visible.** #278's dequeue summary carried the
  injected ruleset condition, in the shape the OR-group builder produces:

  ```
  - [X] any of [🛡 GitHub repository ruleset rule `main-required-ci`]:
    - [X] `check-success = ci`
    - [ ] `check-neutral = ci`
    - [ ] `check-skipped = ci`
  ```

  This is the first live observation of `FORCE_EXEMPTED_RULESET_CONDITIONS_INJECTION`
  since it went `*` (2026-08-12 09:06 UTC) — `kozlek` carries no `excluded` row,
  so it injects.

**And it re-confirms the blocker, now with the queue actually holding survivors.**
The retarget-only shape reproduced exactly as tests D/E predicted: the
`mergify[bot]` installation token gets no cascade rebase, so the survivor keeps
the landed member's original commit while `main` carries it as a new squash
commit — an add/add conflict on the same region. Disjoint-file stacks (Run 1)
escape this; same-file stacks — which is what a real stack usually is — do not.

The fix is atomic run landing (MRGFY-8470, PR **#38508**, still open): one
merge-async call on the top member lands every member below it, so there are no
survivors and no restack. Test F already measured that path at ~3s for 3 members.
Until #38508 ships, whole-stack **queueing** works and whole-stack **landing**
does not.

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
