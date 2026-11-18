# CPS SBOM Platform

Every night, an Azure Function collects GitHub's dependency-graph SBOM for each repository in the org and loads it into [OWASP Dependency-Track](https://dependencytrack.org/). Dependency-Track then shows the team every component, licence and known vulnerability across all repos, and answers "where do we use package X?".

No repository needs any changes. Terraform repos can optionally add one CI job, because GitHub's dependency graph doesn't cover Terraform.

## How it works

```
GitHub org ── dependency graph on for every repo (cps-sbom-baseline)
     │        collector GitHub App (read-only)
     ▼
func-sbom-<env>   02:00 UTC: list repos → queue → fetch each SBOM
     ├─► Blob storage        raw SBOMs, kept 13 months
     └─► Dependency-Track    one project per repo, under a parent project for the org
```

Everything runs in one resource group, `rg-sbom-<env>`, in UK South. The Azure services use public endpoints, and every caller authenticates with Entra ID or an API key. The only long-lived secrets are the GitHub App key and the Dependency-Track API keys, all in Key Vault.

## Repository layout

| Path | Contents |
|---|---|
| `*.tf` | Terraform for the whole platform |
| `sbom-collector/` | The Function App code, its tests, and `ops/` scripts for setting up Dependency-Track |
| `scripts/github/security-config.sh` | Turns on the dependency graph for every repo in the org |
| `.github/workflows/cd.yml` | Deploys Terraform and the collector code |
| `.github/workflows/sbom-setup.yml` | One-off setup after the first deploy |
| `.github/workflows/sbom-scan.yml` | Reusable workflow for Terraform repos |
| `.github/workflows/image-scan.yml`, `container-sbom.yml`, `release-sbom-attest.yml` | Optional reusable workflows for container images |
| `examples/consumer-workflows/` | How other repos call the reusable workflows |

## Documentation

- [Deployment runbook](docs/deployment-runbook.md): deploying from scratch.
- [How to use](docs/how-to-use.md): finding packages and vulnerabilities, running the collector, rotating credentials, troubleshooting.
- [ADR-0001](docs/0001-team-sbom-platform.md): why it's built this way.

## Development

```bash
cd sbom-collector && python3.11 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/ruff check . && .venv/bin/python -m pytest -q
cd .. && terraform init -backend=false && terraform test
```
