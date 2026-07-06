# sandbox — a Mergify test bench

A durable playground for trying Mergify features against real GitHub PRs. The
repo holds the scaffolding below; each thing you want to test is a **scenario**
under `scenarios/`, pushed when you're ready, that spins up its own throwaway PRs
and tears them down — `main` stays put.

## Layout

```
.mergify.yml                 # the ACTIVE config (scopes + queue; currently parallel + skip_intermediate_results)
.github/workflows/ci.yml     # a real CI check named `ci` (pytest) for merge_conditions to gate on
backend/   frontend/         # dummy code = the two file-derived scopes (backend/**, frontend/**)
pyproject.toml               # pytest pythonpath so cross-package imports resolve
scenarios/                   # one folder per experiment (README + run.sh); pushed individually
```

## Scopes

Two file-derived scopes are wired in `.mergify.yml`, reusable by any
parallel/scopes experiment:

| Scope | Files |
|-------|-------|
| `backend`  | `backend/**`  |
| `frontend` | `frontend/**` |

## Running a scenario

Push the scenario folder, then run it:

```bash
git add scenarios/skip-intermediate-results
git commit -m "scenario: skip-intermediate-results"
git push
./scenarios/skip-intermediate-results/run.sh
```

> ⚠️ A scenario may need a specific `.mergify.yml`. `main` already ships the
> parallel + scopes + `skip_intermediate_results` config, so scenario #1 needs no
> config swap. A scenario that needs a different mode should swap `.mergify.yml`
> (Mergify reads config from the default branch) and say so in its README.

## Scenarios

| Scenario | Tests | Status |
|----------|-------|--------|
| [skip-intermediate-results](./scenarios/skip-intermediate-results/) | `skip_intermediate_results` promotes a still-pending ancestor when a downstream child car including it passes — never a failed one — in `parallel` mode | ready to push |
