# AGENTS.md

## Stack

- Bicep for infrastructure (`infra/bicep/`), with `modules/` for shared pieces.
- PowerShell 7 for the scripts that run inside the VNet in Azure Container Instances jobs (`scripts/*.ps1`).
- Python 3 standard library only, for rendering the per-officer definitions (`scripts/per_officer_manifests.py`).
- Tests: `unittest` from the standard library.

## Commands

- Build every template: `for f in infra/bicep/*.bicep; do az bicep build -f "$f" --stdout >/dev/null; done`
- Run the tests: `python3 -m unittest discover -s test`
- Check script syntax: `pwsh -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile("scripts/ingest.ps1",[ref]$null,[ref]$null)'`

## Layout

- `config/officers.json` is the single officer registry. Bicep reads it with `loadJsonContent`, and the scripts read it at run time.
- `infra/bicep/<stage>.bicep` files are deployed separately, in the order in `docs/getting-started.md`.
- `config-job.bicep` embeds `scripts/configure-*.ps1`, and `ingestion.bicep` embeds `scripts/ingest.ps1`. Redeploy the job after changing a script.
