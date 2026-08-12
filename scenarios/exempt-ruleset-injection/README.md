# Ruleset condition injection under an `exempt` bypass

Verifies that a repository ruleset whose Mergify bypass mode is `exempt` still
has its rules injected as Mergify conditions — the behaviour MRGFY-8588 shipped
(PR [#38452], `feat(rules): inject ruleset conditions when Mergify's bypass is
exempt`) behind `FORCE_EXEMPTED_RULESET_CONDITIONS_INJECTION`.

[#38452]: https://github.com/Mergifyio/monorepo/pull/38452

**Why it needs a live check at all.** Before MRGFY-8537, `exempt` meant "the
customer deliberately exempted Mergify from this ruleset" and injection was
skipped. GitHub-native stacks inverted that: the asynchronous Merge API honours
only `exempt`, so customers now have to choose it to get stack merges, and the
old skip would silently drop their enforcement in exchange. The unit tests cover
the branch; what they cannot show is that the whole path — ruleset cache, flag
lookup, condition build, queue evaluation — still lines up against real GitHub.

## The discriminator

`.mergify.yml` on `main` asks for **`check-success=ci`** and nothing else. The
ruleset asks for **`ci` and `probe-check`**, and nothing in this repo ever
produces `probe-check`. So the two outcomes are unmistakable:

| | queue entry | merge |
|---|---|---|
| injection **on** | blocked — `label=queue` matches, injected `probe-check` does not | never reached |
| injection **off** | `label=queue` is the whole condition → queued | `check-success=ci` green → merges |

`ci` alone would prove nothing: it is in `.mergify.yml` too, so seeing it
satisfied says nothing about where the condition came from. `probe-check` exists
only in the ruleset.

Mergify is `exempt`, so GitHub never blocks the merge itself — the injected
condition is the only thing that can. `probe-check` is a plain commit status
posted by hand (a check *run* would need an App); `check-success` matches both.

## Prerequisites

- Ruleset `main-required-ci` (id `20739927`) on `~DEFAULT_BRANCH`, `active`,
  with Mergify (Integration `10562`) as a bypass actor in mode **`exempt`**.
- `FORCE_EXEMPTED_RULESET_CONDITIONS_INJECTION` resolving **enabled** for owner
  `3019422` (`kozlek`) — flag-off is byte-for-byte the historical skip, so a
  negative result means "check the flag" before it means "check the code".
- `gh` authenticated as a repo admin: `PUT /rulesets/{id}` needs it.
- The root `.mergify.yml` is unchanged from the previous scenario — this one
  deliberately reuses it rather than swapping the config, because the whole
  point is that the ruleset contributes a condition the config does not.

## Walkthrough

```bash
scenarios/exempt-ruleset-injection/run.sh            # arm + open + label
# read the summary, confirm probe-check is unchecked, then:
scenarios/exempt-ruleset-injection/run.sh --release <pr head sha>
scenarios/exempt-ruleset-injection/run.sh --release <draft head sha>
scenarios/exempt-ruleset-injection/run.sh --reset    # ALWAYS
```

`--reset` is not optional politeness: an armed `probe-check` holds *every* later
pull request out of the queue, and the summary that says so is three clicks deep.

## Results — 2026-08-12

Probe PR [#286], queue draft [#287].

[#286]: https://github.com/kozlek/sandbox/pull/286
[#287]: https://github.com/kozlek/sandbox/pull/287

**1. Injected, and it blocks queue entry.** With `ci` green and `label=queue`
applied, `Mergify Merge Queue` reported *Waiting for queue conditions to match*:

```
- [ ] any of [🔀 queue conditions]:
  - [ ] all of [📌 queue conditions of queue rule `default`]:
    - [ ] any of [🛡 GitHub repository ruleset rule `main-required-ci`]:
      - [ ] `check-neutral = probe-check`
      - [ ] `check-skipped = probe-check`
      - [ ] `check-success = probe-check`
    - [X] `label=queue`
    - [X] any of [🛡 GitHub repository ruleset rule `main-required-ci`]:
      - [X] `check-success = ci`
```

Both ruleset rules are present, each tagged with its source ruleset. Note `ci`
appears **twice** in the evaluated set — once as the config's own
`check-success=ci`, once as the injected any-of group. That duplication is the
signature of injection actually happening, and it is what a customer will see.

**2. It releases.** Posting `probe-check=success` on the PR head admitted it:
*Entered queue — 13:40 UTC · Rule: `default` · triggered by rule `autoqueue`*.
So the condition is a real gate, not a permanent block.

**3. Injection reaches merge conditions too, evaluated on the draft.** Once
embarked, the same group reappeared under *All merge conditions*, and the batch
sat waiting on `probe-check` — on draft #287, whose head is a different commit
that the hand-posted status did not cover:

```
- [ ] any of [🛡 GitHub repository ruleset rule `main-required-ci`]:
  - [ ] `check-success = probe-check`
- [X] `check-success=ci`
- [X] any of [🛡 GitHub repository ruleset rule `main-required-ci`]:
  - [X] `check-success = ci`
```

Posting the status on the draft head (`4a8b667`) let it through: **merged
13:42:50 UTC**, ~3 minutes end to end.

**Worth carrying out of the bench:** step 3 is the customer-visible sharp edge.
A ruleset-required check that does *not* re-run on the merge queue's draft pull
request will stall the batch once injection is on, where before it was ignored
entirely. `ci` here is fine — the workflow triggers on `pull_request` and the
draft is a pull request — but an external status wired to the original PR only,
or a workflow with a branch filter, is not. This is ordinary merge-queue
behaviour; injection is what widens the set of checks exposed to it.

The merge itself went through GitHub with the ruleset still demanding
`probe-check` on `main` — i.e. the `exempt` bypass did its job at the same time
the injected condition did its job. Both halves in one run.

## What this does *not* cover

- The flag-off path. The flag is enabled for `kozlek`, and it cannot be toggled
  from a read-only session, so "off ⇒ skip" was not re-observed here.
- Rule types other than `required_status_checks`. The `pull_request` (required
  reviews) injection is the other one customers hit; it is untested here because
  the bench has a single human who cannot approve their own pull request.
