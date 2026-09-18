# What GitHub refuses without the `workflows` permission

Exercises MRGFY-9180 (engine #40654, #40655, #40656, all merged 2026-09-15).

**The bug, in two halves.**

1. **Mergify refused too much.** Rebase, merge and copy refused *every* PR
   touching `.github/workflows/` when the installation had not accepted the
   `workflows` permission. That hit 555 live installations, 126 of them active
   in the last 30 days:

   > The new Mergify permissions must be accepted to rebase pull request with
   > `.github/workflows` changes.

2. **When GitHub really refused, Mergify never stopped retrying.** A merge
   refused with HTTP 403 was retried every 3 minutes, indefinitely. The
   up-front refusal above was the only thing keeping that loop from running.

**The fix.** It rests on a measurement, and this scenario replays it: GitHub
refuses an app without `workflows` **only when the operation creates new
workflow content**. A merge that reuses what was already pushed goes through.
So the up-front refusal is gone. A real refusal now dequeues the PR once, with
its own reason (`GITHUB_WORKFLOWS_PERMISSION_MISSING`) and the link to accept
the permission.

## Why this probes GitHub, not Mergify

Mergify's installation on this bench *has* accepted `workflows`, and an
installation's permissions can't be downgraded, so Mergify can't be made to hit
the refusal here. As of 2026-09-18, no production PR has hit it since the fix
shipped either. So this scenario shows GitHub's side live, and the customer
message below comes straight from the engine code.

`GITHUB_TOKEN` is itself a GitHub App installation token, and it can never hold
`workflows`. It is exactly an installation that never accepted the permission.

## Walkthrough (about 1 minute)

Before the demo:

```bash
scenarios/workflows-permission-probe/run.sh setup
```

This opens two PRs that both edit `.github/workflows/ci.yml`:

| PR | Base branch | What the merge writes |
|---|---|---|
| `wfp/head-reuse` → `wfp/base-reuse` | unchanged | the PR's own `ci.yml`, already pushed |
| `wfp/head-3way` → `wfp/base-3way` | also edited `ci.yml` | a 3-way merged `ci.yml` nobody pushed |

Live:

```bash
scenarios/workflows-permission-probe/run.sh go
```

This pushes `wfp/runner`, whose workflow squash-merges both PRs with
`GITHUB_TOKEN`. Open the run
(<https://github.com/kozlek/sandbox/actions/workflows/wfp-probe.yml>):

- **Case 1**: `HTTP/2.0 200 OK`, "Pull Request successfully merged". The old
  Mergify would have refused this PR up front.
- **Case 2**: `HTTP/2.0 403 Forbidden`,
  ``refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission``.
  This is the refusal Mergify used to retry every 3 minutes.

What Mergify now posts on a queued PR that hits case 2 (rendered from the
engine code):

```
## Reason

GitHub refused to update workflow files without the `workflows` permission

## Hint

Merging this pull request writes to `.github/workflows/`, which GitHub only allows with the `workflows` permission.
An organization owner can accept Mergify's pending permissions at https://dashboard.mergify.com/repositories?login=<org>.
```

It's a single dequeue with no retry loop, and it appears in queue statistics
under its own outcome.

Known gap (#40655): when the refusal comes from a *batch*, the whole batch is
dequeued, not only the PR bringing the workflow change, because GitHub's
refusal names a file, not a PR.

## Reset

```bash
scenarios/workflows-permission-probe/run.sh --reset
```

Deletes every `wfp/*` branch. Merged probe PRs stay merged into their throwaway
bases, and `main` is never touched. Run `setup` again for the next rehearsal:
case 1 can only merge once.
