# rebaseable after a base-branch push

Reproduction for a GitHub Support ticket (2026-10-27).

- Pull requests `rebaseable/clean-1` to `clean-4` each add one file: they rebase cleanly.
- `rebaseable/conflict` merges cleanly but cannot be rebased: commit 1 edits line 2 of
  `x.txt`, commit 2 reverts it, commit 3 adds `a.txt`, and this branch then changes line 2
  of `x.txt`.

To reproduce: push a commit to `rebaseable/base` that changes `base.txt`, then read
`GET /repos/kozlek/sandbox/pulls/{n}` for the clean pull requests within a minute.
