# SBOM & Vulnerability Management Platform

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Terraform](https://img.shields.io/badge/terraform-%3E%3D1.10.0-623CE4?logo=terraform&logoColor=white)
[![Terraform CI](https://github.com/cipherfort/sbom-vulnmgmt-platform/actions/workflows/terraform-ci.yml/badge.svg)](https://github.com/cipherfort/sbom-vulnmgmt-platform/actions/workflows/terraform-ci.yml)

Terraform to self-host a shared SBOM ingestion + vulnerability management platform: **Dependency-Track** (SBOM ingestion, continuous CVE monitoring) feeding **DefectDojo**, which is the **single pane across every onboarded repo and finding type** — Terraform/npm SCA, Checkov misconfiguration, and Trivy image findings all land there. Consumed by CI via two reusable workflows: [`.github/workflows/sbom-scan.yml`](.github/workflows/sbom-scan.yml) (Terraform/npm repos) and [`.github/workflows/image-scan.yml`](.github/workflows/image-scan.yml) (container images referenced from Bicep or any other repo, via Trivy).

This platform fills a specific gap: **Terraform providers have no GitHub Dependabot/Dependency-Graph support at all** (verified against current GitHub docs, not assumed), so GitHub's native tooling can't tell you when one of your providers has a published CVE. If you also use GitHub Advanced Security or Dependabot, Checkov and Trivy findings are **dual-written** — SARIF to GitHub's native Security tab (free, gives PR-native annotations) *and* to DefectDojo — so DefectDojo stays a genuine single pane across everything rather than splitting findings across two places. See [ADR-0001](docs/adr/0001-sbom-and-vulnerability-management-platform.md) for the full reasoning.

Deployed on Azure Container Apps — chosen over AKS/a VM because this is two lightly-loaded, CI-driven tools, not a growing workload; revisit if that changes.

**Status: scaffolded, not yet deployed.** Nothing here has been applied. Do the manual bootstrap below, review the Terraform, then apply.

**For background and architecture detail:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) covers the problem statement, tool-landscape comparison, and design rationale. [`docs/adr/0001-sbom-and-vulnerability-management-platform.md`](docs/adr/0001-sbom-and-vulnerability-management-platform.md) is the formal decision record.

**For day-to-day use:** [`docs/how-to-use.md`](docs/how-to-use.md) — operating Dependency-Track and DefectDojo, onboarding another repo, and how Bicep repos are handled differently.

**Licensed under the [MIT License](LICENSE).** Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Architecture

```
GitHub Actions (any onboarded repo)
    │  cdxgen → bom.json → upload
    ▼
Dependency-Track (ca-<name_prefix>-dt-api, ca-<name_prefix>-dt-fe)
    │  Postgres "dtrack" database
    │  continuous CVE re-scoring
    ▼
GitHub Actions polls DT → exports findings → imports into
    ▼
DefectDojo (ca-<name_prefix>-dd-web [uwsgi+nginx], dd-worker, dd-beat)
    │  Postgres "defectdojo" database, Redis broker
    ▼
One product/engagement per repo — a single pane for vulnerability management across every onboarded repo
```

All five apps run in one Container Apps Environment (`cae-<name_prefix>`), share one PostgreSQL Flexible Server (two databases), and pull secrets from one Key Vault (`kv-<name_prefix>-*`) via user-assigned managed identities — no secrets in Terraform state beyond what Azure itself requires, no secrets in git. `<name_prefix>` is whatever you set for the `name_prefix` variable, letting multiple deployments coexist in one subscription/tenant without name collisions.

## Repo layout

- **`modules/platform/`** — the actual Terraform resources, as a reusable module. No backend, no provider config — compose it into your own Terraform with `module { source = "github.com/cipherfort/sbom-vulnmgmt-platform//modules/platform" }` if you'd rather not use this repo's own deployable example.
- **`examples/standalone/`** — the deployable root that most people actually want: a thin wrapper calling `modules/platform`, with the real backend/provider config and `terraform.tfvars.example`. **All `terraform` commands below run from this directory.**

## Quickstart

```bash
./scripts/bootstrap.sh --github-owner <you> --github-repo <repo> --name-prefix <yours>
```

Automates the manual Bootstrap steps below (state storage, OIDC App Registration, workload resource group, RBAC) and prints the GitHub secrets to set — skip to step 4 below using its output. Safe to re-run. See `./scripts/bootstrap.sh --help` for options, and `scripts/teardown-bootstrap.sh` to undo it.

## Bootstrap (manual, one-time) — what the script does, if you'd rather do it by hand or understand it

Uses the standard GitHub Actions OIDC pattern for authenticating to Azure without a long-lived credential: an Azure AD App Registration with federated credentials trusting your GitHub repo/branch, RBAC-scoped to just what this platform needs.

**The Terraform state storage names below (`rg-tfstate-security-platform`, `stsecplatstate001`) and the App Registration name (`sp-security-platform-github-actions`) are examples, not requirements — pick your own naming and update `examples/standalone/versions.tf`'s `backend` block to match.** Terraform backend blocks can't reference variables, so this is a manual find-and-replace, not something you set once in a `.tfvars` file. The workload resource group (`rg-<name_prefix>`) is different — that one's driven by the `name_prefix` variable (see step 3), not hardcoded.

1. **Create the Terraform state storage** (referenced by `examples/standalone/versions.tf`'s backend block — update the placeholder names there if you use different ones):
   ```bash
   az group create --name rg-tfstate-security-platform --location uksouth
   az storage account create \
     --name stsecplatstate001 \
     --resource-group rg-tfstate-security-platform \
     --location uksouth --sku Standard_LRS --kind StorageV2 \
     --allow-blob-public-access false --https-only true
   az storage container create \
     --name terraform-state --account-name stsecplatstate001 --auth-mode login
   ```

2. **App Registration + OIDC federated credentials.** One `branch:main` credential covers `cd.yml`; add a `pull_request` credential too if you later add a plan-on-PR workflow:
   ```bash
   az ad app create --display-name "sp-security-platform-github-actions"
   APP_ID=$(az ad app list --display-name "sp-security-platform-github-actions" --query '[0].appId' -o tsv)
   az ad sp create --id "$APP_ID"
   az ad app federated-credential create --id "$APP_ID" --parameters '{
     "name": "secplat-cd-main",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:cipherfort/sbom-vulnmgmt-platform:ref:refs/heads/main",
     "audiences": ["api://AzureADTokenExchange"]
   }'
   ```
   If you've forked this repo, substitute your own `owner/repo` in the `subject` field.

3. **RBAC** — `Contributor` scoped to a dedicated resource group, since this workload provisions real infrastructure. This resource group's name must match `rg-<name_prefix>`, where `<name_prefix>` is whatever you set for the `name_prefix` variable — Terraform creates it, but the role assignment below has to be pre-scoped to it before the first apply:
   ```bash
   az group create --name rg-<name_prefix> --location uksouth
   SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
   az role assignment create --assignee "$SP_OBJECT_ID" --role "Contributor" \
     --scope "/subscriptions/<id>/resourceGroups/rg-<name_prefix>"
   az role assignment create --assignee "$SP_OBJECT_ID" --role "Storage Blob Data Contributor" \
     --scope "/subscriptions/<id>/resourceGroups/rg-tfstate-security-platform/providers/Microsoft.Storage/storageAccounts/stsecplatstate001"
   ```

4. **GitHub repo secrets** (Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `AZURE_CLIENT_ID` | App Registration client ID |
   | `AZURE_TENANT_ID` | Azure AD tenant ID |
   | `AZURE_SUBSCRIPTION_ID` | Target subscription |
   | `ALLOWED_IP_RANGES` | JSON list, e.g. `["203.0.113.0/24","198.51.100.4/32"]` — your office/VPN egress ranges. Feeds `TF_VAR_allowed_ip_ranges`. **Note:** `sbom-scan.yml`/`image-scan.yml` run on GitHub-hosted `ubuntu-latest` runners by default, which don't have stable IPs — their calls into this platform won't pass a real allowlist unless you switch those workflows to a self-hosted runner with known egress, or widen this list. See "Known gaps" below. |

5. **GitHub Environment** `security-platform` (Settings → Environments) — add required reviewers if you want an approval gate before `terraform apply` on push to `main`.

6. Push this repo, open a PR to sanity-check `terraform plan` output (`workflow_dispatch` → `plan`), then merge to apply.

## First login

- **Dependency-Track**: default `admin`/`admin`, forced password change on first login — no way to pre-seed this via Terraform/env var. Do this immediately after deploy, then generate a Teams → API key for CI (that's the value for `DEPENDENCY_TRACK_API_KEY` in consuming repos).
- **DefectDojo**: `admin` / the value in Key Vault secret `defectdojo-admin-password`. Generate an API v2 key from the user menu for CI (`DEFECTDOJO_API_KEY` in consuming repos).

## Onboarding another repo

See [`docs/how-to-use.md`](docs/how-to-use.md) §4 for the full step-by-step (secrets/variables, the `sbom-scan.yml` call, Terraform vs. npm, when to set `import_to_defectdojo`). Bicep repos are intentionally not onboarded — §5 of that guide covers why and what to do instead.

## Known gaps / next hardening steps

- **Networking**: by default, ingress is external HTTPS + IP allowlist, and Postgres/Key Vault are reachable from any Azure service. Set `enable_private_networking = true` to move Postgres and Key Vault onto a VNet with private endpoints (public access disabled on both, restricted to an IP allowlist for Key Vault since Terraform itself needs data-plane access to write secrets) — Container Apps ingress stays public either way, so GitHub-hosted CI runners keep working unchanged. This is "data plane" hardening, not full network isolation; see `docs/ARCHITECTURE.md` §5 for the tradeoff.
- **GitHub-hosted runners vs. IP allowlisting**: if you use the default `ubuntu-latest` runners in `sbom-scan.yml`/`image-scan.yml`, their calls into this platform come from GitHub's large, dynamic runner IP pool, which a real `allowed_ip_ranges` allowlist can't practically cover. Either use a self-hosted runner with known static egress, or accept broader ingress exposure — there's no way to have both hosted runners and a tight allowlist. See the `ALLOWED_IP_RANGES` note above.
- **No HA by default**: single Postgres instance (`B_Standard_B1ms`), `min_replicas = 1` everywhere. Set `high_availability_enabled = true` for zone-redundant Postgres (this requires switching to a General Purpose SKU — HA is not supported on the Burstable tier despite what `az postgres flexible-server list-skus`' capability schema suggests, confirmed against a real deployment) and 2 replicas on every Container App. Redis already runs HA by default regardless of this flag (Azure Managed Redis defaults to `high_availability_enabled = true`).
- **Backups**: relies on Postgres Flexible Server's built-in 7-day backup retention. No tested restore procedure yet.
- **Bicep registry-module provenance**: `image-scan.yml` covers container images referenced from a Bicep template, but nothing scans externally-published Bicep modules themselves — there's no CVE database for that. Pin-to-digest and PR review remain the control; see `docs/how-to-use.md` §5a.
- **`image-scan.yml`'s `image_refs` is a manually-maintained list**, not auto-discovered from `.bicep` files — it can drift out of sync with what a template actually references if nobody updates it when the template changes.
