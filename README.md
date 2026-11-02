# CPS Enterprise SBOM Platform

One Azure-hosted collector pulls GitHub's dependency-graph SBOM for every repository in every org of our GitHub Enterprise Cloud account each night. The SBOMs go to three places:
- **OWASP Dependency-Track**, where each team sees its own components, licences and vulnerabilities.
- **Microsoft Sentinel**, where CPS answers "where do we run package X?" in one KQL query.
- **Blob storage**, for 13 months of history.

**Status: built on branch, not deployed.** Nothing here has been applied. What is left to do, phase by phase, is in [`docs/enterprise-sbom/delivery-plan.md`](docs/enterprise-sbom/delivery-plan.md).

| Read | For |
|---|---|
| [ADR-0002](docs/adr/0002-enterprise-sbom-platform.md) | The decision, and where the build departs from the design doc |
| [Deployment runbook](docs/enterprise-sbom/deployment-runbook.md) | Every step from a fresh copy of this repo to enterprise-wide collection, with commands |
| [Delivery plan](docs/enterprise-sbom/delivery-plan.md) | Phase 0–3 checklists, corrections to the design doc, open questions |
| [How to use](docs/how-to-use.md) | Operating model, onboarding an org, Terraform CI path, failure runbook |

This replaces the earlier per-repo platform with DefectDojo ([ADR-0001](docs/adr/0001-sbom-and-vulnerability-management-platform.md), superseded).

---

## Architecture

```
GitHub Enterprise Cloud
  every org ── cps-sbom-baseline (dependency graph enforced)
            ── cps-sbom-collector App (read-only)  ◄── cps-app-installer adds it to new orgs
        │ list repos · generate-report → fetch-report (async)
        ▼
rg-sbom-prd (UK South, landing-zone VNet, private endpoints)
  func-sbom-prd (Flex Consumption, Python 3.11)
    enumerate_repos  02:00 UTC ─► sbom-work queue ─► collect_sbom (re-queues while GitHub builds)
    sync_dtrack_acl  04:30 UTC   report_poison_depth /15 min   install_collector_on_new_orgs Mon 03:00
        │
        ├─► stsbomprd/sbom-raw            raw SPDX, versioned, Cool 30 d, delete 13 months
        ├─► Dependency-Track 4.14          cae-sbom-prd (internal) · ca-dtrack-api/ui · psql-dtrack-prd
        │     <org> parent ─ <org>/<repo>  (collector)  ─ <org>/<repo>/terraform  (sbom-scan.yml)
        └─► CPS Sentinel workspace         GitHubSbom_CL · GitHubSbomRun_CL · SbomLatest · workbook · rule
```

Every Azure hop uses a managed identity. The only long-lived secrets are the GitHub App private keys and the Dependency-Track API keys, all in `kv-sbom-prd`.

## What is where

| Path | What |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Root module. Reads the pre-created `rg-sbom-<env>`; checks it is in a UK region |
| `keyvault.tf`, `storage.tf`, `postgres.tf` | Key Vault, collector storage, Dependency-Track `/data` share, Postgres. All behind private endpoints |
| `dependency_track.tf` | Internal Container Apps environment (workload profiles), API server and frontend, private DNS for the environment |
| `collector.tf` | Function App, its identity and roles, Application Insights |
| `sentinel.tf` | Custom tables, DCE/DCR, `SbomLatest`, workbook, `BannedPackages` watchlist, analytics rule |
| `monitoring.tf` | Action group, poison-queue and enumeration alerts, diagnostic settings |
| `entra.tf` | Optional (`manage_entra`): Entra groups and the Dependency-Track app registration |
| `tests/plan.tftest.hcl` | Full plan against mocked providers (`terraform test`) |
| `sbom-collector/` | The Function App: `function_app.py`, `convert.py` (SPDX → CycloneDX), `dtrack.py`, tests, KQL |
| `sbom-collector/ops/dtrack_admin.py` | Dependency-Track bootstrap, org onboarding, ACL sync |
| `poc/` | Local proof of concept: the collector against real GitHub, with Dependency-Track and Azurite in Docker ([poc/README.md](poc/README.md)) |
| `scripts/github/security-config.sh` | Creates and applies the `cps-sbom-baseline` enterprise security configuration |
| `.github/workflows/` | `cd.yml` (Terraform + collector deploy), `sbom-collector-ci.yml`, and the reusable `sbom-scan.yml`, `image-scan.yml`, `container-sbom.yml`, `release-sbom-attest.yml` |

## Deploying it

Follow the [deployment runbook](docs/enterprise-sbom/deployment-runbook.md), step by step:
- what to change when you copy this repo to another org;
- the Azure and GitHub bootstrap (state storage, deployer identity and roles, secrets);
- the first apply and the Dependency-Track setup;
- the pilot collection;
- Entra sign-in;
- the enterprise rollout.

Every step has its commands and a check.

Two things catch people out:
- **The deployer's federated credential subject is `repo:<org>/<repo>:environment:security-platform`, not a branch ref.** Both `cd.yml` jobs run in that environment, and GitHub then puts the environment in the token subject.
- **The deployer needs more than Contributor.** It also needs Role Based Access Control Administrator, conditioned, on `rg-sbom-<env>`, plus roles on the CPS workspace's resource group, the landing-zone VNet and the DNS zones. See runbook step 6.

## Known gaps

- **One replica of Dependency-Track.** A dashboard outage during patching is acceptable; the data is safe in Postgres and Blob and can be replayed.
- **Default branch only.** The SBOM shows the default branch, not what is deployed. Phase 3's attested release SBOMs cover services that adopt them.
- **Rate-limited collection.** GitHub's `dependency_sbom` limit bounds how fast a large estate is collected; see the delivery plan's corrections table.
- **Corporate access to Dependency-Track** depends on the landing zone forwarding the environment's DNS domain (output `container_apps_domain`).
