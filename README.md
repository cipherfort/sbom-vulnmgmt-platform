# CPS SBOM Platform

An Azure-hosted collector pulls GitHub's dependency-graph SBOM for every repository in the CPS GitHub org each night. The SBOMs go to two places:
- **OWASP Dependency-Track**, where CPS sees components, licences and vulnerabilities, triages findings, and searches for a package across every repo.
- **Blob storage**, for 13 months of history.

**Status: built on branch, not deployed in production.** The design was test-deployed end to end on 6 Nov 2026 in its enterprise form; this single-org version has passed `terraform test` and the collector tests but has not been applied yet.

| Read | For |
|---|---|
| [ADR-0001](docs/adr/0001-team-sbom-platform.md) | The decision, the security trade-offs, and what the build learned |
| [Deployment runbook](docs/deployment-runbook.md) | Every step from a fresh copy of this repo to nightly collection, with commands |
| [How to use](docs/how-to-use.md) | Day-to-day use, the Terraform CI path, rotating credentials, failure runbook |

---

## Architecture

```
GitHub: CPS org ── cps-sbom-baseline (dependency graph on, every repo)
                ── cps-sbom-collector App (org-owned, read-only, all repositories)
        │ list repos · generate-report → fetch-report (async)
        ▼
rg-sbom-<env> (UK South, public endpoints, no VNet)
  func-sbom-<env> (Flex Consumption, Python 3.11)
    enumerate_repos 02:00 UTC ─► sbom-work queue ─► collect_sbom (re-queues while GitHub builds)
    report_poison_depth every 15 min
        │
        ├─► stsbom<env>/sbom-raw         raw SPDX, versioned, Cool 30 d, delete 13 months
        └─► Dependency-Track 4.14        cae-sbom-<env> · ca-dtrack-api (open, key-protected)
              <org> parent                ca-dtrack-ui (allowed_ip_ranges) · psql-dtrack-<env>
               ├─ <org>/<repo>            (collector)
               └─ <org>/<repo>/terraform  (sbom-scan.yml)
  log-sbom-<env> · appi-sbom-<env> · alerts to alert_email
```

Every Azure hop uses a managed identity or Entra ID. The only long-lived secrets are the GitHub App private key and the Dependency-Track API keys, all in `kv-sbom-<env>`.

## What is where

| Path | What |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Root module. Reads the pre-created `rg-sbom-<env>`; checks it is in a UK region |
| `keyvault.tf`, `storage.tf`, `postgres.tf` | Key Vault, collector storage, Dependency-Track `/data` share, Postgres |
| `dependency_track.tf` | Container Apps environment (workload profiles), API server and frontend |
| `collector.tf` | Function App, its identity and roles, Application Insights |
| `monitoring.tf` | Log Analytics workspace, action group, poison-queue and enumeration alerts, diagnostic settings |
| `entra.tf` | Optional (`manage_entra`): the two Entra groups and the Dependency-Track app registration |
| `tests/plan.tftest.hcl` | Full plan against mocked providers (`terraform test`) |
| `sbom-collector/` | The Function App: `function_app.py`, `convert.py` (SPDX → CycloneDX), `dtrack.py`, tests, the App Insights status query |
| `sbom-collector/ops/` | `first_setup.py` (first Dependency-Track login and setup) and `dtrack_admin.py` (teams, keys, policies, org parent) |
| `poc/` | Local proof of concept: the collector against real GitHub, with Dependency-Track and Azurite in Docker ([poc/README.md](poc/README.md)) |
| `scripts/github/security-config.sh` | Creates and applies the `cps-sbom-baseline` org security configuration |
| `.github/workflows/` | `cd.yml` (Terraform + collector deploy), `sbom-collector-ci.yml`, and the reusable `sbom-scan.yml`, `image-scan.yml`, `container-sbom.yml`, `release-sbom-attest.yml` |

## Deploying it

Follow the [deployment runbook](docs/deployment-runbook.md). It needs no landing zone: a subscription, a resource group, and an org owner on GitHub. Every step has its commands and a check.

Two things catch people out:
- **The deployer's federated credential subject is `repo:<org>/<repo>:environment:security-platform`, not a branch ref.** Both `cd.yml` jobs run in that environment, and GitHub then puts the environment in the token subject.
- **The deployer needs more than Contributor.** It also needs Role Based Access Control Administrator, conditioned, on `rg-sbom-<env>`. See runbook step 5.

## Known gaps

- **The Dependency-Track API is internet-facing**, protected by API keys and sign-in. See ADR-0001 for why, and the alternative if that isn't acceptable.
- **One replica of Dependency-Track.** A dashboard outage during patching is acceptable; the data is safe in Postgres and Blob and can be replayed.
- **Default branch only.** The SBOM shows the default branch, not what is deployed. `release-sbom-attest.yml` covers services that adopt it.
- **Rate-limited collection.** GitHub allows 100 SBOMs an hour per org, so an org of a few hundred repos takes a few hours on its first night.
