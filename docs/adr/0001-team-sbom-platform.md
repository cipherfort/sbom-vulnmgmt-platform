# ADR-0001: CPS SBOM platform — GitHub dependency graph into Dependency-Track

## Status

Proposed — 2026-11-11. Replaces the earlier ADRs for this repo: the per-repo DefectDojo platform on `main`, and the enterprise-wide design on branch `feature/enterprise-sbom-platform`. Both are in git history.

## Context

CPS wants to know what every one of its repositories depends on, see the known vulnerabilities and licences in those dependencies, and answer "where do we use package X?" quickly during an incident.

The platform on `main` built this repo by repo. Each repo called a reusable workflow that made an SBOM and uploaded it to Dependency-Track, which fed DefectDojo. Coverage depended on every repo wiring up CI.

The enterprise design that followed collected every org in the GitHub Enterprise. It added Microsoft Sentinel for search and private networking in a landing zone. After discussion, the team decided the platform is **for CPS only**:

- **One GitHub org:** the CPS org, and all of its repositories.
- **An org-owned GitHub App**, so no enterprise owner is needed.
- **No Sentinel.**
- **No private endpoints or subnets.** This matches `main` and keeps operating overhead low.

GitHub already builds an SBOM for every repository from its dependency graph. It is removing the synchronous SBOM export on **13 November 2026**, so the collector uses the asynchronous `generate-report` and `fetch-report` endpoints.

## Decision

1. **The source of truth is GitHub's dependency-graph SBOM (SPDX 2.3).** The org security configuration `cps-sbom-baseline` turns it on for every repo (`scripts/github/security-config.sh`). The org-owned GitHub App `cps-sbom-collector` reads it. The App is installed on the CPS org with all repositories and has read-only Contents and Metadata.
2. **One collector**: an Azure Functions app (Python 3.11, Flex Consumption) in `rg-sbom-<env>`, UK South.
   - A nightly timer queues repos that changed, plus a rolling 1/7 of the rest.
   - A queue worker drives the async SBOM API by re-queueing rather than sleeping.
   - Each SBOM is archived raw to Blob for 13 months of history, converted to CycloneDX 1.5, and loaded into Dependency-Track.
3. **Dependency-Track is the only dashboard.** It does continuous vulnerability matching (NVD, OSV, GitHub Advisories), licence policy, per-finding analysis states, and component search across the portfolio. That covers the incident lookup. DefectDojo and Sentinel are not used.
4. **One team, two roles.** People sign in with Entra ID. `sg-sbom-cps-admins` administers Dependency-Track; `sg-sbom-cps-users` views and triages findings. Portfolio access control is off, because everyone who can sign in may see every project.
5. **No private networking. Every service uses its public endpoint and authenticates every caller.**

   | Service | Who can connect | What protects it |
   |---|---|---|
   | Storage (collector) | Anyone on the internet | Shared keys are off; every caller needs Entra ID and a data role |
   | Key Vault | Anyone on the internet | RBAC only |
   | Postgres | Azure services only (`AllowAzureServices`) | A generated 32-character password, TLS required |
   | Dependency-Track API | Anyone on the internet | An API key or a signed-in session on every call except `/api/version` |
   | Dependency-Track UI | `allowed_ip_ranges`, as on `main` | Entra sign-in |

   The API can't be IP-restricted. A Flex Consumption Function has no fixed outbound IP without VNet integration and a NAT gateway, and the UI calls the API from each person's browser.
6. **`sbom-scan.yml` stays, for Terraform only.** The dependency graph has no Terraform ecosystem. Terraform SBOMs are uploaded as `<org>/<repo>/terraform` under the same org parent, so they don't overwrite the collector's `<org>/<repo>` project.
7. **Infrastructure is Terraform in this repo**, deployed by `cd.yml` with OIDC. The collector code is in `sbom-collector/`.

### Facts that shaped the build

These were found building and test-deploying the enterprise version (6 Nov 2026) and this version (11 Nov 2026).

- **Rate limit.** `generate-report` has its own `dependency_sbom` bucket: 100 an hour per App installation, measured 1 Nov 2026. The general 15,000 an hour doesn't apply.
  - The collector parks throttled jobs until the limit resets.
  - It forces an unchanged repo on one stable weekday, not all on Sunday.
  - One org of up to about 2,400 repos is collected in a night.
- **Dependency-Track 4.13+** is needed for the org's parent collection project. The image is pinned to 4.14.6.
- **User-assigned identities**, so the Key Vault roles exist before the apps start. With system-assigned identities, Container Apps' Key Vault secret reference hits a chicken-and-egg problem.
- **One keyed storage account.** `stdtrack<env>` keeps an account key, because Container Apps Azure Files mounts only support keys. It holds only rebuildable caches.
- **Contributor isn't enough for the deployer.** Terraform creates role assignments, so the deployer also needs Role Based Access Control Administrator on `rg-sbom-<env>`, conditioned to the roles the platform grants.
- **azurerm quirks** seen in the test deployment:
  - `azurerm_function_app_flex_consumption` writes an `AzureWebJobsStorage` connection string with an empty key. That overrides the identity settings, so the collector sets it to empty. See `collector.tf`.
  - `azurerm_storage_table` uses the data plane, so the table is created with azapi.
  - A Key Vault recovered from soft delete keeps its old firewall, because azurerm doesn't apply `network_acls` on recovery. `keyvault.tf` sets the firewall explicitly, so the next apply corrects it.
- **The org security configuration API needs `admin:org`**, not the `write:org` the docs give. Orgs without the unbundled Advanced Security plan reject the `code_security` and `secret_protection` fields, even as `not_set`. `security-config.sh` handles both.
- **The baseline matters.** Before `cps-sbom-baseline` was applied, 6 of the 9 test repos returned `no-dependency-graph`. After it was applied, all 9 were collected.
- **Failure visibility.** There is no per-queue length metric. The poison-queue depth is logged every 15 minutes and alerted on. A second alert fires if enumeration hasn't succeeded in 26 hours.

## Considered alternatives

| Alternative | Why not |
|---|---|
| The enterprise design (every org, Sentinel, private endpoints) | Built for a scope the team doesn't want. It also brings the landing-zone dependencies: three subnets, six private DNS zones, corporate DNS forwarding, and a jump box to reach Dependency-Track. |
| A small VNet with a NAT gateway for the Function only, so the API can be IP-restricted | About £30 a month and one more network to run, to protect an API that already needs a key on every call. Worth revisiting if the API must not be internet-facing. |
| Keep the per-repo CI model from `main` | Coverage depends on every repo adding CI, and nothing measures the repos that haven't. |
| Keep DefectDojo | A second self-hosted app, plus Redis and a database, for cross-tool aggregation this design doesn't need. |
| Sentinel for search | Dependency-Track's component search answers "where do we use X" for one org. Sentinel adds ingestion cost and a workspace dependency. |
| GitHub Actions or a Container Apps job instead of Functions | Functions gives the timer and queue triggers, retries, scale-to-zero and managed identity with the least code. |

## Consequences

**Positive**
- Every non-archived repo in the CPS org is covered, with no per-repo setup.
- New CVEs show up on old SBOMs without re-collecting, because Dependency-Track re-analyses continuously.
- No landing-zone work, no jump box, and no DNS forwarding. People open Dependency-Track from any allowed network, and any GitHub runner can upload.
- 38 Terraform resources, against 54 for the enterprise design plus its 30-resource landing zone.
- No long-lived human credentials. The long-lived secrets are the GitHub App private key and the Dependency-Track API keys, all in Key Vault.

**Negative / accepted risk**
- **The Dependency-Track API is on the internet.** A Dependency-Track vulnerability would be exposed directly. Mitigations: patch within 7 days of a security release, and remove the local admin once Entra sign-in works.
- **Postgres accepts connections from any Azure-hosted IP.** The password and TLS are the control.
- **Default branch only.** The SBOM shows the default branch, not what is deployed. `release-sbom-attest.yml` closes that gap for services that adopt it.
- **The dependency graph misses things**: repos without a lockfile, unsupported ecosystems, and container images until `container-sbom.yml` is adopted. Those repos show as `no-dependency-graph`.
- **Dependency-Track runs as one replica.** A dashboard outage during patching is acceptable; the data is in Postgres and Blob and can be replayed.
- **Other teams aren't covered.** Extending to another org means installing the App there and running `onboard-org`. Separating teams' views would need portfolio access control and per-team Entra groups.

## Related documents

- [deployment-runbook.md](../deployment-runbook.md): every step to deploy it, with commands.
- [how-to-use.md](../how-to-use.md): day-to-day use, rotating credentials, failure runbook.
- [README.md](../../README.md): architecture and repo layout.
