# Enterprise SBOM platform — delivery plan

Working checklist for the design in *Enterprise SBOM Platform — Design & Delivery Plan* (26 Oct 2026). The decision record is [ADR-0002](../adr/0002-enterprise-sbom-platform.md); day-to-day operation is in [how-to-use.md](../how-to-use.md).

Each item is tagged:

- **[code]** — built on branch `feature/enterprise-sbom-platform`; the item is done once that code is reviewed, merged and applied.
- **[manual]** — someone has to do it in GitHub, Entra or Dependency-Track; no code can.
- **[check]** — a verification step or a gate.

Dates are the design doc's, assuming one engineer at about half time.

## Corrections to the design doc found while building

These changed the build. Each one is explained in ADR-0002.

| # | Design doc says | Reality, and what the branch does |
|---|---|---|
| 1 | Each org installation has 15,000 requests/hour, so a Sunday refresh of 1,000 repos is trivial | `generate-report` has **its own rate-limit bucket** (`x-ratelimit-resource: dependency_sbom`, 100/hour seen on a user token, 27 Oct 2026). The collector already parks throttled jobs until the reset. The Sunday full refresh is replaced by a **rolling refresh**: each repo gets a stable weekday, so about 1/7 of the estate is forced each night. Measure the App installation's limit in Phase 1. |
| 2 | Collection projects need Dependency-Track 4.12+ | They arrived in **4.13.0**. The image is pinned to **4.14.6**. |
| 3 | Portfolio access control on the org parent limits each team to its org | Dependency-Track 4.x access control is **per project and not inherited**. A team on the parent can't see the children. The collector runs a nightly `sync_dtrack_acl` that puts each org's team on every project under its parent, using a separate `acl-sync` API key. |
| 4 | The installer checks `app_id` in the org's installation list | The list response has `client_id`, not `app_id`. The design doc's check would never match and would re-install on every org every week. The branch matches on `client_id`. |
| 5 | Alert on poison-queue length | Azure Monitor has no per-queue length metric. A 15-minute timer logs the depth and a log alert fires on it. A second alert fires if the nightly enumeration hasn't succeeded in 26 hours. |
| 6 | `host.json` with only queue settings | No `extensionBundle` means the queue trigger won't load, and no `visibilityTimeout` means the 5 retries fire back to back. Both are added. |
| 7 | A message that fails 5 times goes to poison | It went to poison silently: no row in `GitHubSbomRun_CL`, so coverage didn't show it. The last attempt now writes status `error`, and the coverage query counts it as Failed. |
| 8 | System-assigned identities | User-assigned, so the Key Vault roles exist before the apps start (the Container Apps secret-reference chicken-and-egg). |
| 9 | "No connection strings with keys" | One exception: a Container Apps Azure Files mount only supports account keys (`stdtrackprd`, private endpoint only, holds only caches). |
| 10 | Contributor is enough to deploy | Terraform creates role assignments, so the deployer also needs **Role Based Access Control Administrator** (conditioned) on `rg-sbom-prd`, plus rights on the workspace and landing-zone resources. See README, Bootstrap. |
| 11 | Enterprise config with paid features "off" | `disabled` with enforcement would switch GHAS code scanning and secret protection **off** where teams use them today. The script sets paid features to `not_set`. |
| 12 | Collector `PUT /bom` with `parentName` | Uses `parentUUID` from a find-or-create of the parent. A new org needs no manual parent project before its first upload. |

## Phase 0 — Prepare (27 Oct – 6 Nov 2026)

- [ ] **[manual]** Agree scope and this design with the CPS lead; record the decisions at the end of this page.
- [ ] **[manual]** Confirm the Azure subscription, the landing-zone VNet and three subnets, and the private DNS zones. These become the `vnet_id`, `*_subnet_id` and `private_dns_zone_ids` inputs.
  - Function integration subnet, delegated to `Microsoft.App/environments`.
  - Container Apps infrastructure subnet, /27 or larger, delegated to `Microsoft.App/environments`.
  - Private endpoint subnet.
- [ ] **[manual]** Confirm `cps-ubuntu-latest-private` can reach the landing-zone VNet: the Key Vault private endpoint (Terraform writes the Postgres password) and the internal Dependency-Track (`sbom-scan.yml` uploads). If it can't reach Key Vault, set `deployer_ip_ranges`.
- [ ] **[manual]** Ask the landing-zone team to forward the Container Apps environment's domain (output `container_apps_domain`) from corporate DNS, so people can reach Dependency-Track.
- [ ] **[manual]** Register the `Microsoft.App` resource provider in the subscription (needed for the subnet delegation).
- [ ] **[manual]** Take Dependency-Track (Apache 2.0) through the open-source approval route.
- [ ] **[manual]** Confirm the Sentinel workspace (input `cps_workspace_id`) and who pays for ingestion.
- [ ] **[manual]** Create the Entra groups `sg-sbom-cps-admins` and one `sg-sbom-org-<org>` per org. Alternatively, set `manage_entra = true` in Phase 2.
- [ ] **[manual]** Search our repos for scripts calling the old `/dependency-graph/sbom` endpoint and warn their owners before **13 Nov 2026**:
  `gh search code "dependency-graph/sbom" --owner <org>` for each org.
- [ ] **[manual]** Bootstrap Azure: state storage, the deployer's federated credential and roles, `rg-sbom-prd`, and the `TF_VARS_JSON` secret (README, Bootstrap).
- [ ] **[check]** Gate: design agreed.

## Phase 1 — Pilot on the CPS org (9 – 20 Nov 2026)

### Step 1 — GitHub enterprise policy (pilot scope)
- [ ] **[code]** `scripts/github/security-config.sh` creates `cps-sbom-baseline`: dependency graph, automatic dependency submission and Dependabot alerts enabled, paid features `not_set`, enforced.
- [ ] **[manual]** As an enterprise owner, run `scripts/github/security-config.sh --enterprise <slug> --pilot-org <cps-org>`.
- [ ] **[check]** The org-level attach of an enterprise configuration is the one call not confirmed against the docs. If it returns 404, apply the configuration to the pilot org in the UI.

### Step 2 — Create the collector GitHub App
- [ ] **[manual]** Enterprise → Settings → GitHub Apps → New GitHub App `cps-sbom-collector`, webhook off.
- [ ] **[manual]** Repository permissions: Contents read, Metadata read, Dependabot alerts read. Installable only on this enterprise.
- [ ] **[manual]** Generate a private key and store it: `az keyvault secret set --vault-name kv-sbom-prd -n github-app-private-key --file cps-sbom-collector.private-key.pem`. Then delete the `.pem` securely.
- [ ] **[manual]** Record the App ID in `TF_VARS_JSON` (`github_app_id`).
- [ ] **[manual]** Install the App on the CPS org with *All repositories*.

### Step 3 — Azure foundation
- [ ] **[code]** `keyvault.tf`, `storage.tf`, `collector.tf`, `monitoring.tf`: Key Vault (RBAC mode, purge protection, private endpoint), `stsbomprd` (shared keys off; `sbom-raw` with versioning, Cool at 30 days, deleted at 13 months; `sbom-work`, `sbom-work-poison`, `repostate`), the Flex Consumption Function App (VNet-integrated, user-assigned identity with least-privilege roles), Application Insights, and alerts.
- [ ] **[manual]** Merge to `main`, or run `cd.yml` with `plan`, review, then `apply`.

### Step 4 — Dependency-Track
- [ ] **[code]** `postgres.tf`, `dependency_track.tf`:
  - `psql-dtrack-prd` (GP D2ds_v5, v16, 64 GB, private endpoint).
  - The internal `cae-sbom-prd` with workload profiles.
  - `ca-dtrack-api` 4.14.6 (4 vCPU / 8 GiB, 1 replica, `/data` on Azure Files) and `ca-dtrack-ui`.
  - OIDC env vars, set only once a client ID exists.
- [ ] **[manual]** First login as `admin`, change the password, and create a temporary admin API key for the next step.
- [ ] **[code]** `sbom-collector/ops/dtrack_admin.py bootstrap`:
  - Portfolio access control on; NVD, OSV and GitHub Advisories sources on.
  - Teams `bom-uploader`, `ci-uploader`, `acl-sync` and `sg-sbom-cps-admins`. API keys go straight to Key Vault: `dtrack-api-key`, `dtrack-ci-api-key`, `dtrack-acl-key`.
  - The `CPS restricted` licence group and the three starter policies (warn/info).
- [ ] **[manual]** Run it with `GITHUB_ADVISORIES_TOKEN` set to a read-only GitHub token: `python ops/dtrack_admin.py bootstrap --key-vault-url https://kv-sbom-prd.vault.azure.net/`.
- [ ] **[manual]** Register the Entra app for Dependency-Track (or let `manage_entra` do it in Phase 2):
  - SPA redirect `https://ca-dtrack-ui.<env-domain>/static/oidc-callback.html`.
  - `groups` claim as `cloud_displayname` for assigned groups.
  - Put its client ID in `dtrack_oidc_client_id` and apply.
- [ ] **[manual]** Sign in through Entra as a member of `sg-sbom-cps-admins`, then disable the local `admin` account and delete the temporary key.
- [ ] **[code]** `python ops/dtrack_admin.py onboard-org <cps-org>` creates the CPS parent collection project, team, OIDC mapping and access.

### Step 5 — Sentinel tables and ingestion
- [ ] **[code]** `sentinel.tf`: `GitHubSbom_CL` (90 days) and `GitHubSbomRun_CL` (365 days, with the Phase 3 Dependabot columns), `dce-sbom-prd`, `dcr-sbom-prd`, and Monitoring Metrics Publisher for the collector. The table schema and DCR stream share one column list, so they can't drift.

### Step 6 — Deploy and prove the collector
- [ ] **[code]** `cd.yml` `collector-deploy` packages `sbom-collector/` with its dependencies on the runner and deploys it to Flex Consumption.
- [ ] **[manual]** Set the repo variable `FUNCTION_APP_NAME` (output `function_app_name`).
- [ ] **[manual]** Trigger `enumerate_repos` by hand: Portal → Function App → `enumerate_repos` → Test/Run.
- [ ] **[check]** Expect:
  - One blob per CPS repo under `sbom-raw/<org>/`.
  - Projects `<org>/<repo>` under parent `<org>` in Dependency-Track.
  - Rows in both Sentinel tables.
- [ ] **[check]** Compare three repos by hand against **Insights → Dependency graph** in GitHub.
- [ ] **[check]** Note the `x-ratelimit-limit` the App installation gets for `dependency_sbom` (App Insights request logs, or one `curl -i` with an installation token). Then re-check the sizing in the decisions table.
- [ ] **[check]** Run `sbom-scan.yml` from this repo (`test-sbom-scan.yml`) and confirm `<org>/cps-security-platform-infra/terraform` lands under the same parent.
- [ ] **[check]** **Gate:** five consecutive nights with no poison-queue messages and no `sbom-enumerate-not-succeeded` alert.

## Phase 2 — Enterprise rollout (23 Nov – 18 Dec 2026)

- [ ] **[manual]** Brief every org owner: what is collected, who sees it, and what is expected of them (Operating model in how-to-use.md).
- [ ] **[manual]** Review the existing enterprise configurations the script lists, then run `scripts/github/security-config.sh --enterprise <slug> --enterprise-wide`. That widens `cps-sbom-baseline` to repos with no configuration and makes it the default for new repos. Add the same three settings to any other configuration teams use, or re-run with `--include-configured`.
- [ ] **[manual]** Create the GitHub App `cps-app-installer` with the enterprise *organization installations* (read and write) permission. Install it on the **enterprise**, not on orgs.
- [ ] **[manual]** Store its key as `github-installer-private-key` in Key Vault, then set `github_installer_app_id` and `github_installer_installation_id` and apply.
- [ ] **[code]** `install_collector_on_new_orgs` runs Mondays at 03:00 UTC. It installs `cps-sbom-collector` with all repositories on any org without it, and switches existing installs from "selected" to "all". It does nothing until the installer app ID is set.
- [ ] **[check]** Run the installer once by hand and confirm the log line for each org.
- [ ] **[code]** `entra.tf` (opt-in, `manage_entra = true`):
  - `sg-sbom-cps-admins` and `sg-sbom-org-<org>` for each entry in `sbom_orgs`.
  - The Dependency-Track app registration, which emits group display names and requires assignment.
  - The deployer needs Graph `Group.ReadWrite.All` and `Application.ReadWrite.OwnedBy`.
- [ ] **[manual]** Either set `manage_entra` and `sbom_orgs`, or create the groups and app by hand. Add each team's nominated members.
- [ ] **[manual]** For each org, run `python ops/dtrack_admin.py onboard-org <org> --teams-webhook <url>`.
- [ ] **[code]** `sync_dtrack_acl` (04:30 UTC nightly) keeps each org team's access current as repos appear. It reports parents with no team yet.
- [ ] **[code]** `sentinel.tf`:
  - The `SbomLatest` saved function.
  - The workbook *SBOM coverage and inventory*: coverage by org, stale or failed, licence watch, version sprawl, Dependabot by org.
  - The `BannedPackages` watchlist (seeded from `banned_packages`).
  - The scheduled rule *SBOM: banned package in use*.
- [ ] **[manual]** Agree the initial `banned_packages` list with CPS security.
- [ ] **[manual]** Decommission the old stack: `rg-security-platform` (DefectDojo, the old Dependency-Track, Redis) and its state key `security-platform.tfstate`. Export anything worth keeping first. Then delete the `DEFECTDOJO_*` variables and secrets from consuming repos.
- [ ] **[check]** **Gate:** at least 95% of active repos have a fresh SBOM (workbook coverage tile), and every org team can sign in and sees only its own org.

## Phase 3 — Depth (Jan – Mar 2027)

- [ ] **[code]** Dependabot alert counts per repo: the collector reads open alerts at collection time into `GitHubSbomRun_CL.Dependabot{Critical,High,Medium,Low}`, with a workbook tile. It never fails a collection; repos with alerts off get no counts.
- [ ] **[code]** `.github/workflows/container-sbom.yml`: Syft image SBOM → dependency submission API. The collector then picks it up with no platform change. Example: `examples/consumer-workflows/container-image.yml`.
- [ ] **[manual]** Pick two image-building repos to adopt it, on their default-branch build.
- [ ] **[code]** `.github/workflows/release-sbom-attest.yml`: release SBOM plus `actions/attest-sbom` bound to the image digest.
- [ ] **[manual]** Pilot it on one service, and verify with `gh attestation verify`.
- [ ] **[manual]** Review licence policies with legal and procurement. Inputs: the `CPS restricted` group and the *Restricted or unknown licence in distributed service* policy, which applies to projects tagged `distributed`. Decide which teams tag their projects.
- [ ] **[manual]** After three months, decide whether any policy moves from warn to fail.

## Open questions (from the design doc, plus new ones)

- [ ] How many orgs and active repositories do we have today? This drives the rate-limit sizing (correction 1) and Sentinel cost.
- [ ] Are we on Enterprise Managed Users? This changes how Entra groups map to GitHub teams.
- [ ] Which Azure subscription and landing zone host this, and who pays for Sentinel ingestion?
- [ ] Does Dependency-Track need a formal open-source approval or a DPIA screening?
- [ ] Are any orgs out of scope (sandboxes, archived programmes)?
- [ ] Who in each team is the named owner for findings?
- [ ] **New:** what `dependency_sbom` limit does an App installation get? If it is 100/hour per installation, a large org needs the rolling refresh, and the first collection takes several nights.
- [ ] **New:** do Teams channels still accept Dependency-Track's MessageCard webhooks (Office 365 connectors are being retired)? If not, point the notification at a Power Automate workflow URL.
- [ ] **New:** what do we export from DefectDojo before decommissioning, if anything?

## Decisions needed

| Decision | Proposed | Owner |
|---|---|---|
| Dashboard tool | OWASP Dependency-Track 4.14.x, self-hosted on Azure; DefectDojo removed | CPS lead |
| Collection frequency | Nightly for changed repos, plus a rolling weekly refresh (1/7 of repos a night) | CPS platform |
| Data classification | OFFICIAL-SENSITIVE | Information assurance |
| Policy mode for first 3 months | Warn only, no build blocking | CPS security |
| Raw SBOM retention | 13 months in Blob, Cool tier after 30 days | Information assurance |
| CPS "sees everything" mechanism | `sg-sbom-cps-admins` team has ACCESS_MANAGEMENT, which bypasses portfolio access control in Dependency-Track 4.x | CPS security |
