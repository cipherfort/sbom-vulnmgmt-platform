# ADR-0002: Enterprise SBOM platform — GitHub dependency graph into Dependency-Track and Sentinel

## Status

Proposed — 2026-10-27. Supersedes [ADR-0001](0001-sbom-and-vulnerability-management-platform.md).

## Context

ADR-0001 built SBOM coverage repo by repo: each repo called a reusable workflow that generated an SBOM and uploaded it to Dependency-Track, which fed DefectDojo. Coverage depended on every team wiring CI, and only onboarded repos were visible.

CPS holds the enterprise owner role on our GitHub Enterprise Cloud account. GitHub already builds an SBOM for every repository from its dependency graph. What we lack is an enterprise-wide view: one place to answer "where do we run package X?" in minutes during an incident (F4), and coverage numbers per org (F5).

GitHub is also removing the synchronous SBOM export on **13 November 2026**. Anything built now must use the asynchronous `generate-report` / `fetch-report` endpoints.

The full design, with requirements F1–F7 and N1–N5, is *Enterprise SBOM Platform — Design & Delivery Plan* (26 Oct 2026). The working checklist is [docs/enterprise-sbom/delivery-plan.md](../enterprise-sbom/delivery-plan.md).

## Decision

1. **Source of truth is GitHub's dependency graph SBOM (SPDX 2.3)**, enforced on every repo through the enterprise security configuration `cps-sbom-baseline`. It is collected by the enterprise-owned GitHub App `cps-sbom-collector`, installed on every org (and kept installed by `cps-app-installer`).
2. **One collector**: an Azure Functions app (Python, Flex Consumption) in `rg-sbom-prd`, UK South. A nightly timer queues changed repos, and a queue worker drives the async SBOM API by re-queueing rather than sleeping. Each SBOM is archived raw to Blob (history, F2), converted to CycloneDX 1.5 and loaded into Dependency-Track, and a flattened copy goes to Sentinel.
3. **Dependency-Track is the only dashboard. DefectDojo is removed.** Dependency-Track already gives continuous vulnerability matching, licence policy, per-finding analysis state and per-team views. DefectDojo's extra value was cross-tool aggregation of CI scanners, which this design doesn't need:
   - Trivy image findings stay in GHAS (SARIF).
   - Image components reach the inventory through the dependency submission API.
   - Dependabot alerts are counted into Sentinel.
4. **Sentinel is the search and coverage layer.** CPS runs KQL against the custom tables `GitHubSbom_CL` and `GitHubSbomRun_CL` in the CPS workspace, fed through the Logs Ingestion API.
5. **Isolation (N2).** Each org has a Dependency-Track parent collection project, a team named after its Entra group `sg-sbom-org-<org>`, and an OIDC mapping. CPS security (`sg-sbom-cps-admins`) sees everything.
6. **`sbom-scan.yml` stays, for Terraform only.** The dependency graph still has no Terraform ecosystem (the gap ADR-0001 was written for). Terraform SBOMs are uploaded as `<org>/<repo>/terraform` under the same org parent. The different name stops them overwriting the collector's `<org>/<repo>` project.
7. **Infrastructure is Terraform in this repo**, not the design doc's `az` CLI runbook. The collector code lives in `sbom-collector/`.

### Where the build departs from the design doc

The delivery plan lists each departure with its evidence. In short:

- **Rate limits.** `generate-report` has its own `dependency_sbom` bucket (100/hour observed on a user token). The design doc assumed the general 15,000/hour.
  - The weekly Sunday full refresh becomes a rolling refresh: each repo gets a stable weekday.
  - Throttled jobs are parked until the limit resets.
  - The Function is capped at 4 instances per function (at most about 48 concurrent GitHub calls).
- **Dependency-Track version.** Collection projects need **4.13+** (pinned to 4.14.6). Portfolio access control in 4.x is **not inherited** from the parent, so a nightly sync grants each org's team access to every child project. It uses a separate `acl-sync` key, so the upload key stays least-privileged.
- **Identities** are user-assigned rather than system-assigned, so Key Vault access exists before the apps start.
- **One keyed storage account.** `stdtrackprd` keeps an account key, because Container Apps Azure Files mounts only support keys. It is private-endpoint-only and holds rebuildable caches.
- **Paid GHAS features** are `not_set` in `cps-sbom-baseline`, not `disabled`. An enforced `disabled` would switch them off where teams use them.
- **Installer.** It matches existing installations on `client_id`; the list API has no `app_id`.
- **Failure visibility.** A message's last failed attempt is written to `GitHubSbomRun_CL` as `error`. Poison-queue depth is logged every 15 minutes and alerted on, because there is no per-queue metric.

## Considered alternatives

| Alternative | Why not |
|---|---|
| Keep ADR-0001's per-repo CI model as the main path | Coverage depends on every team adding CI; no enterprise-wide view; no coverage measure for repos nobody onboarded. |
| Keep DefectDojo alongside Dependency-Track | Two self-hosted apps, Redis and a Postgres database to patch, for aggregation this design no longer needs. Findings would live in two places with no sync (ADR-0001's own accepted risk). |
| Separate Dependency-Track per org | Many instances to run; no portfolio view for CPS. Portfolio access control gives isolation in one instance. |
| Azure Data Explorer instead of Sentinel | Another platform to run. Sentinel is already where CPS investigates, and KQL joins with existing detections. |
| Container Apps job or GitHub Actions instead of Functions | No queue-driven polling or scale-to-zero (Actions); Functions gives timer + queue triggers, VNet integration and managed identity with the least code. |
| Commercial SCA | Licence cost that scales with repo count; data leaves our tenant. |

## Consequences

**Positive**
- Every non-archived repo in every org is covered, with no per-repo setup, and coverage is measurable per org.
- Incident lookup by package is one KQL function (`SbomLatest`).
- New CVEs light up old SBOMs without re-collecting, because Dependency-Track re-analyses continuously.
- One self-hosted app instead of two, and no Redis.
- Nothing long-lived holds human credentials. The only long-lived secrets are the GitHub App private keys and the Dependency-Track API keys, all in Key Vault.

**Negative / accepted risk**
- **Default branch only.** The SBOM shows what is on the default branch, not what is deployed. This is stated on the workbook; Phase 3's release-time attested SBOMs close the gap for services that adopt them.
- **The dependency graph misses things:** no lockfile, unsupported ecosystems, and containers (until `container-sbom.yml` is adopted). The coverage panel shows `no-dependency-graph`.
- **Collection is bounded by GitHub's SBOM rate limit.** The first collection of a large org can take several nights.
- **Dependency-Track runs as one replica.** A dashboard outage during patching is acceptable; the data is safe in Postgres and Blob and can be replayed.
- **CPS admins get ACCESS_MANAGEMENT** in Dependency-Track, because that permission is the 4.x bypass for portfolio access control. That is more than "view everything".
- **Removing DefectDojo drops its ticketing and SLA tracking.** Triage state now lives in Dependency-Track's analysis states.

## Related documents

- [docs/enterprise-sbom/delivery-plan.md](../enterprise-sbom/delivery-plan.md) — phase checklists, corrections to the design doc, open questions
- [docs/how-to-use.md](../how-to-use.md) — operating the platform, onboarding an org, failure runbook
- [README.md](../../README.md) — architecture and bootstrap
