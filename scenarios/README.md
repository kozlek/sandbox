# Scenarios

One folder per Mergify feature you want to exercise. Each is **pushed
individually** — the bench starts without any scenarios, and you add them as you
go.

A scenario folder contains:

- `README.md` — what it tests, prerequisites, and the live walkthrough.
- `run.sh` — opens the scenario's throwaway PRs (and `--reset` tears them down).
  It never touches `main`.

If a scenario needs a different `.mergify.yml` than what's on `main`, its README
says so and you swap the root config before running it.

| Scenario | Tests |
|----------|-------|
| `skip-intermediate-results` | `skip_intermediate_results` in `parallel` mode (MRGFY-7620) |
