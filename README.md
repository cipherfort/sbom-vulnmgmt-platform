# CPS Enterprise SBOM Platform

One Azure-hosted collector pulls GitHub's dependency-graph SBOM for every repository in every org of our GitHub Enterprise Cloud account each night. The SBOMs go to three places:
- **OWASP Dependency-Track**, where each team sees its own components, licences and vulnerabilities.
- **Microsoft Sentinel**, where CPS answers "where do we run package X?" in one KQL query.
- **Blob storage**, for 13 months of history.

**Status: built on branch, not deployed.** Nothing here has been applied. What is left to do, phase by phase, is in [`docs/enterprise-sbom/delivery-plan.md`](docs/enterprise-sbom/delivery-plan.md).

| Read | For |
|---|---|
| [ADR-0002](docs/adr/0002-enterprise-sbom-platform.md) | The decision, and where the build departs from the design doc |
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

## Bootstrap (manual, one-time)

1. **Terraform state storage.** Reuses the existing account; the state key is `sbom-platform.tfstate`:
   ```bash
   az group create --name rg-tfstate-security-platform --location uksouth
   az storage account create --name stsecplatstate001 --resource-group rg-tfstate-security-platform \
     --location uksouth --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false --https-only true
   az storage container create --name terraform-state --account-name stsecplatstate001 --auth-mode login
   ```

2. **Deployer identity with an OIDC federated credential for `main`:**
   ```bash
   az ad app create --display-name "sp-sbom-platform-github-actions"
   APP_ID=$(az ad app list --display-name "sp-sbom-platform-github-actions" --query '[0].appId' -o tsv)
   az ad sp create --id "$APP_ID"
   az ad app federated-credential create --id "$APP_ID" --parameters '{
     "name": "sbom-cd-main",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:sg-cloud-platform/cps-security-platform-infra:ref:refs/heads/main",
     "audiences": ["api://AzureADTokenExchange"]
   }'
   SP=$(az ad sp show --id "$APP_ID" --query id -o tsv)
   ```

3. **Resource group and roles.** Terraform creates role assignments, so Contributor alone is not enough:
   ```bash
   RG=/subscriptions/<sub>/resourceGroups/rg-sbom-prd
   az group create --name rg-sbom-prd --location uksouth
   az role assignment create --assignee-object-id "$SP" --assignee-principal-type ServicePrincipal --role Contributor --scope "$RG"
   # Lets Terraform grant only the data-plane roles the platform uses.
   az role assignment create --assignee-object-id "$SP" --assignee-principal-type ServicePrincipal \
     --role "Role Based Access Control Administrator" --scope "$RG" \
     --condition-version 2.0 --condition "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {00482a5a-887f-4fb3-b363-3b7fe8e74483, 4633458b-17de-408a-b874-0445c86b69e6, b7e6dc6d-f1e8-4753-8033-0f276bb0955b, 974c5e8b-45b9-4653-ba55-5f855dd0fb88, 0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3, 3913510d-42f4-4e42-8a64-420c390055eb}))"
   az role assignment create --assignee-object-id "$SP" --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" \
     --scope /subscriptions/<sub>/resourceGroups/rg-tfstate-security-platform/providers/Microsoft.Storage/storageAccounts/stsecplatstate001
   ```
   The GUIDs are, in order: Key Vault Administrator, Key Vault Secrets User, Storage Blob Data Owner, Storage Queue Data Contributor, Storage Table Data Contributor and Monitoring Metrics Publisher.

   Outside the resource group, the deployer also needs:
   - **CPS workspace and its resource group:** Log Analytics Contributor (tables, saved function), Microsoft Sentinel Contributor (watchlist, analytics rule) and Workbook Contributor.
   - **Landing zone:** permission to join the three subnets (`Microsoft.Network/virtualNetworks/subnets/join/action`) and to link and register records in the private DNS zones and the VNet. Network Contributor on the VNet plus Private DNS Zone Contributor on the zones covers this, or use the landing zone's own equivalent role.
   - **Only with `manage_entra = true`:** Microsoft Graph `Group.ReadWrite.All` and `Application.ReadWrite.OwnedBy`.

4. **GitHub secrets and variables** (Settings → Secrets and variables → Actions):

   | Name | Kind | Value |
   |---|---|---|
   | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | secret | Deployer from step 2 |
   | `TF_VARS_JSON` | secret | [`terraform.tfvars.example`](terraform.tfvars.example) as JSON: landing-zone IDs, workspace ID, GitHub App ID, alert email |
   | `FUNCTION_APP_NAME` | variable | Output `function_app_name`, set after the first apply |
   | `DEPENDENCY_TRACK_URL` / `DEPENDENCY_TRACK_API_KEY` | variable / secret | Only for `test-sbom-scan.yml`: the API URL and the `ci-uploader` key |

5. **GitHub Environment `security-platform`.** Add required reviewers to gate `terraform apply` and the collector deploy.

6. Run `cd.yml` with `plan`, review the plan, then merge or run `apply`. Then follow Phase 1 steps 2–6 of the delivery plan: GitHub App and key, Dependency-Track bootstrap, collector proof.

## First login to Dependency-Track

The default login is `admin`/`admin`, with a forced password change; nothing can pre-seed it. Sign in from the corporate network, change the password, and create a temporary API key on the Administrators team. Then run `sbom-collector/ops/dtrack_admin.py bootstrap`, which turns on portfolio access control, the vulnerability sources, the teams and keys (written straight to Key Vault) and the starter policies.

Once Entra sign-in works for `sg-sbom-cps-admins`, disable the local `admin` and delete the temporary key.

## Known gaps

- **One replica of Dependency-Track.** A dashboard outage during patching is acceptable; the data is safe in Postgres and Blob and can be replayed.
- **Default branch only.** The SBOM shows the default branch, not what is deployed. Phase 3's attested release SBOMs cover services that adopt them.
- **Rate-limited collection.** GitHub's `dependency_sbom` limit bounds how fast a large estate is collected; see the delivery plan's corrections table.
- **Corporate access to Dependency-Track** depends on the landing zone forwarding the environment's DNS domain (output `container_apps_domain`).
