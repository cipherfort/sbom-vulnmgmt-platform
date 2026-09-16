# Security Platform Infra

Terraform for the team's shared SBOM + vulnerability management platform: **Dependency-Track** (SBOM ingestion, continuous CVE monitoring) feeding **DefectDojo**, which is the **single pane across every onboarded repo and finding type** — Terraform/npm SCA, Checkov misconfiguration, and Trivy image findings all land there. Consumed by CI in the IaC repos via two reusable workflows: [`.github/workflows/sbom-scan.yml`](.github/workflows/sbom-scan.yml) (Terraform/npm repos — starting with `cps-azure-policy-as-code-terraform`) and [`.github/workflows/image-scan.yml`](.github/workflows/image-scan.yml) (container images referenced from Bicep or any other repo, via Trivy).

This platform exists specifically to cover what **GitHub Advanced Security (GHAS) Enterprise — already licensed — does not**: Terraform providers have no Dependabot/Dependency-Graph support at all (verified against current GitHub docs, not assumed). Checkov and Trivy findings are **dual-written** — SARIF to GHAS's native Security tab (free, gives PR-native annotations) *and* to DefectDojo (so DefectDojo stays authoritative across everything, not just Dependency-Track's findings). See [ADR-0001](docs/adr/0001-sbom-and-vulnerability-management-platform.md).

Deployed on Azure Container Apps — chosen over AKS/a VM because this is two lightly-loaded, CI-driven internal tools, not a growing workload; revisit if that changes.

**Status: scaffolded, not yet deployed.** Nothing here has been applied. Do the manual bootstrap below, review the Terraform, then apply.

**For the team / decision record:** [`docs/team-presentation.md`](docs/team-presentation.md) covers the problem statement, tool-landscape comparison, and rollout plan. [`docs/adr/0001-sbom-and-vulnerability-management-platform.md`](docs/adr/0001-sbom-and-vulnerability-management-platform.md) is the formal decision record.

**For day-to-day use:** [`docs/how-to-use.md`](docs/how-to-use.md) — operating Dependency-Track and DefectDojo, onboarding another repo, and how Bicep repos are handled differently.

---

## Architecture

```
GitHub Actions (any onboarded repo)
    │  cdxgen → bom.json → upload
    ▼
Dependency-Track (ca-dtrack-api, ca-dtrack-frontend)
    │  Postgres "dtrack" database
    │  continuous CVE re-scoring
    ▼
GitHub Actions polls DT → exports findings → imports into
    ▼
DefectDojo (ca-defectdojo-web [uwsgi+nginx], celeryworker, celerybeat)
    │  Postgres "defectdojo" database, Redis broker
    ▼
One product/engagement per repo — the team's single vuln-management pane
```

All five apps run in one Container Apps Environment (`cae-security-platform`), share one PostgreSQL Flexible Server (two databases), and pull secrets from one Key Vault (`kv-secplat-*`) via user-assigned managed identities — no secrets in Terraform state beyond what Azure itself requires, no secrets in git.

## Bootstrap (manual, one-time)

Mirrors how `cps-azure-policy-as-code-terraform` bootstraps its own Azure account access — see that repo's `docs/github-actions-setup.md` for the pattern this follows.

1. **Create the Terraform state storage** (referenced by `versions.tf`'s backend block — update the placeholder names there if you use different ones):
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

2. **App Registration + OIDC federated credentials**, same two-credential pattern as the policy repo (`pull_request` won't apply here since this repo has no CI-plan-on-PR workflow yet — just add the `branch:main` credential for `cd.yml`):
   ```bash
   az ad app create --display-name "sp-security-platform-github-actions"
   APP_ID=$(az ad app list --display-name "sp-security-platform-github-actions" --query '[0].appId' -o tsv)
   az ad sp create --id "$APP_ID"
   az ad app federated-credential create --id "$APP_ID" --parameters '{
     "name": "secplat-cd-main",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:sg-cloud-platform/cps-security-platform-infra:ref:refs/heads/main",
     "audiences": ["api://AzureADTokenExchange"]
   }'
   ```

3. **RBAC** — `Contributor` on a dedicated resource group is simplest here (unlike the policy repo, this workload owns real infrastructure, not just policy assignments):
   ```bash
   az group create --name rg-security-platform --location uksouth
   SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
   az role assignment create --assignee "$SP_OBJECT_ID" --role "Contributor" \
     --scope "/subscriptions/<id>/resourceGroups/rg-security-platform"
   az role assignment create --assignee "$SP_OBJECT_ID" --role "Storage Blob Data Contributor" \
     --scope "/subscriptions/<id>/resourceGroups/rg-tfstate-security-platform/providers/Microsoft.Storage/storageAccounts/stsecplatstate001"
   ```

4. **GitHub repo secrets** (Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `AZURE_CLIENT_ID` | App Registration client ID |
   | `AZURE_TENANT_ID` | Azure AD tenant ID |
   | `AZURE_SUBSCRIPTION_ID` | Target subscription |
   | `ALLOWED_IP_RANGES` | JSON list, e.g. `["203.0.113.0/24","198.51.100.4/32"]` — office/VPN egress + the `cps-ubuntu-latest-private` runner's egress. Feeds `TF_VAR_allowed_ip_ranges`. |

5. **GitHub Environment** `security-platform` (Settings → Environments) — add required reviewers if you want an approval gate before `terraform apply` on push to `main`.

6. Push this repo, open a PR to sanity-check `terraform plan` output (`workflow_dispatch` → `plan`), then merge to apply.

## First login

- **Dependency-Track**: default `admin`/`admin`, forced password change on first login — no way to pre-seed this via Terraform/env var. Do this immediately after deploy, then generate a Teams → API key for CI (that's the value for `DEPENDENCY_TRACK_API_KEY` in consuming repos).
- **DefectDojo**: `admin` / the value in Key Vault secret `defectdojo-admin-password`. Generate an API v2 key from the user menu for CI (`DEFECTDOJO_API_KEY` in consuming repos).

## Onboarding another repo

See [`docs/how-to-use.md`](docs/how-to-use.md) §4 for the full step-by-step (secrets/variables, the `sbom-scan.yml` call, Terraform vs. npm, when to set `import_to_defectdojo`). Bicep repos are intentionally not onboarded — §5 of that guide covers why and what to do instead.

## Known gaps / next hardening steps

- **Networking**: ingress is external HTTPS + IP allowlist, not a private VNet. Fine for MVP; move both the Container Apps Environment and PostgreSQL Flexible Server onto a shared VNet with private endpoints once this holds real production vuln data.
- **DefectDojo image internals**: the static/media volume mount paths and entrypoint env vars in `defectdojo.tf` were written from the well-established public docker-compose reference, not verified against a running container — confirm against the pinned `defectdojo_image_tag` release's `docker-compose.yml` before first apply, they occasionally shift between releases.
- **No HA**: single Postgres instance (`B_Standard_B1ms`), single Redis node, `min_replicas = 1` everywhere. Revisit sizing once real usage is known.
- **Backups**: relies on Postgres Flexible Server's built-in 7-day backup retention. No tested restore procedure yet.
- **Bicep registry-module provenance**: `image-scan.yml` covers container images referenced from a Bicep template, but nothing scans externally-published Bicep modules themselves — there's no CVE database for that. Pin-to-digest and PR review remain the control; see `docs/how-to-use.md` §5a.
- **`image-scan.yml`'s `image_refs` is a manually-maintained list**, not auto-discovered from `.bicep` files — it can drift out of sync with what a template actually references if nobody updates it when the template changes.
