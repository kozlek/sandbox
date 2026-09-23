# changed-files-from-git

Does the engine list a pull request's changed files with `git` once GitHub's own
list is truncated? (MRGFY-7706, flag `CHANGED_FILES_FROM_GIT_FOR_ORGS`.)

## What is being tested

`GET /pulls/{n}/files` stops at **3 000 entries**, with no error and no
`rel="next"` — while `pull["changed_files"]` stays accurate. Above the cap the
engine clones the repository and reads `git diff --raw --no-renames` between the
merge base and the head instead.

The probe changes **3 501** files: `bulk/f0001.txt` … `bulk/f3500.txt`, plus
`zzz-past-the-cap.txt`, which sorts last. GitHub's truncated list therefore
cannot contain the marker — `run.sh setup` prints the proof — so the
`bigdiff-probe` queue rule on `main` admits the pull request **only** if the
engine is reading the complete list:

```yaml
queue_conditions:
  - "label=bigdiff-probe"
  - "files=bulk/f0001.txt"      # entry 1: the control, true either way
  - "files=zzz-past-the-cap.txt" # entry 3 501: true only from git
```

`merge_conditions` gate on `manual-gate`, a commit status nobody posts, so the
probe enters the queue and stays there. Nothing ever merges.

## Prerequisites

- `CHANGED_FILES_FROM_GIT_FOR_ORGS` enabled for `kozlek` (github_account 3019422).
- The `bigdiff-probe` queue rule present in `.mergify.yml` on `main`.

## Walkthrough

```
scenarios/changed-files-from-git/run.sh setup   # opens the probe, prints the truncation
scenarios/changed-files-from-git/run.sh go      # labels it
scenarios/changed-files-from-git/run.sh --reset # tears it all down
```

What to watch:

- **Summary check-run** on the probe — `files=zzz-past-the-cap.txt` ✅ is the
  result. ❌ means the engine is still on GitHub's list.
- **The queue** — the probe enters it and sits on `manual-gate`.
- **Datadog** — `engine.context.changed_files_from_git` with `result:success`,
  and its duration histogram. `undercount` / `overcount` mean `changed_files`
  disagrees with what git found, `failure` means git could not answer.

## Gotchas

- **The config simulator will not show this.** `_files_come_from_git` requires
  `logs.WORKER_TASK`, which only a worker sets; an API request authenticates as
  the same installation but is deliberately excluded, so a simulation reads
  GitHub's truncated list and the marker condition comes back ❌.
- A **closed** pull request is excluded too, so re-check the probe while it is
  open.
