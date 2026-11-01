# How to use — Enterprise SBOM platform (Dependency-Track + Sentinel)

This guide covers day-to-day use of the platform, onboarding an org, the Terraform CI path, container images, and what to do when something breaks. *Why* it is built this way: [ADR-0002](adr/0002-enterprise-sbom-platform.md). *What is left to do*: [delivery plan](enterprise-sbom/delivery-plan.md). *Deploying it*: [README](../README.md).

**Data classification: OFFICIAL-SENSITIVE.** An SBOM lists every library and version a service runs, which tells an attacker where to aim. No public dashboards, access by named group only, and no export outside the platform without CPS sign-off.

---

## Table of contents

1. [Where things live](#1-where-things-live)
2. [Operating model](#2-operating-model)
3. [Dependency-Track for teams](#3-dependency-track-for-teams)
4. [Sentinel for CPS](#4-sentinel-for-cps)
5. [Onboarding an org](#5-onboarding-an-org)
6. [Terraform repos: `sbom-scan.yml`](#6-terraform-repos-sbom-scanyml)
7. [Container images and Bicep repos](#7-container-images-and-bicep-repos)
8. [Running the collector](#8-running-the-collector)
9. [Rotating credentials](#9-rotating-credentials)
10. [Failure runbook](#10-failure-runbook)

---

## 1. Where things live

```
GitHub (every org)  ── dependency graph, enforced by cps-sbom-baseline
   │  cps-sbom-collector App (read-only)
   ▼
func-sbom-prd  enumerate_repos 02:00 UTC → sbom-work queue → collect_sbom
   │  sync_dtrack_acl 04:30 UTC · report_poison_depth every 15 min · installer Mondays 03:00 UTC
   ├─► Blob   stsbomprd/sbom-raw/<org>/<repo>/<date>.spdx.json   history, 13 months
   ├─► Dependency-Track  <org>/<repo> under parent <org>         teams work findings here
   └─► Sentinel  GitHubSbom_CL, GitHubSbomRun_CL                 CPS search and coverage
```

Dependency-Track is internal only; reach it on the corporate network. Get the URLs with `terraform output dependency_track_url` (UI) and `dependency_track_api_url` (API).

**Default branch only.** The SBOM shows what is on each repo's default branch, which is not necessarily what is deployed. Release-time attested SBOMs (§7) close that gap for services that adopt them.

## 2. Operating model

CPS runs the platform and owns enterprise-wide visibility. Each team owns the findings in its own repos. The platform tells teams what they run; it does not fix it for them.

| Activity | CPS platform | CPS security | Org team | Information assurance |
|---|---|---|---|---|
| Run collector, Dependency-Track, Sentinel tables | R/A | C | I | I |
| Enterprise security configuration | R/A | C | I | I |
| Onboard a new org | R | A | C | I |
| Triage findings in a team's repos | I | C | R/A | I |
| Set vulnerability and licence policies | C | R/A | C | C |
| Incident lookup ("where is package X") | C | R/A | C | I |
| Access reviews (quarterly) | R | A | C | I |

| Service level | Level |
|---|---|
| Collection | Nightly. Changed repos no older than 24 hours; every repo no older than 7 days (rolling refresh) |
| Platform support | Working hours, CPS backlog |
| Critical finding triage by owning team | 5 working days |
| Dependency-Track patching | Within 30 days of a new 4.x release; within 7 days for a security release |

Policies are **warn only** for the first three months. Nothing here blocks a build.

## 3. Dependency-Track for teams

Sign in with your Entra account. You see your org's parent project and every repo under it; nothing else.

| Project | Version | From |
|---|---|---|
| `<org>` | — | Parent collection project: rolls up the metrics of its children |
| `<org>/<repo>` | default branch | The nightly collector (GitHub dependency graph) |
| `<org>/<repo>/terraform` | `main` or `pr-<n>` | `sbom-scan.yml` in the repo's CI (Terraform providers) |

- **Vulnerabilities**: matched continuously against NVD, GitHub Advisories and OSV. A CVE published next month shows up on today's SBOM without re-collecting.
- **Audit**: set an *analysis state* (exploitable, not affected, false positive, …) with a justification. That is the triage record, and the triage-speed KPI counts from first finding to analysis state set.
- **Policy violations**: the starter policies are critical/high vulnerability (warn), restricted or unknown licence in a project tagged `distributed` (warn), and component 3+ major versions behind (info). Tag a project `distributed` if the service ships outside CPS.
- **Notifications**: new vulnerabilities and policy violations go to your org's Teams channel, if one was given at onboarding.

## 4. Sentinel for CPS

The workbook **SBOM coverage and inventory** has these tiles: coverage by org, stale or failed repos, licence watch, version sprawl, and open Dependabot alerts by org. The queries are in [`sbom-collector/kql/`](../sbom-collector/kql/).

Incident lookup, which is the F4 requirement and an exercise target of under 5 minutes:

```kusto
SbomLatest
| where PackageName has "log4j-core" or Purl has "log4j-core"
| project Org, Repo, Branch, PackageName, PackageVersion, Purl
| order by Org asc, Repo asc
```

`SbomLatest` is a saved workspace function: the latest snapshot per repo over 8 days. `PackageName` is the name GitHub's SBOM uses, for example `@azure/core-rest-pipeline`, `actions/checkout`, `log4j-core`. Use `Purl` to be exact.

**Banned packages.** Add a row to the `BannedPackages` watchlist (Sentinel → Watchlist, or `banned_packages` in Terraform). The *SBOM: banned package in use* rule raises an incident for every repo whose latest SBOM contains it, once a day.

**Run statuses in `GitHubSbomRun_CL`:**

| Status | Meaning |
|---|---|
| `ok` | SBOM collected and loaded |
| `skipped` | Archived, disabled or empty repo |
| `no-dependency-graph` | GitHub returned 404: no manifests, or the repo isn't under `cps-sbom-baseline` |
| `timeout` | GitHub's SBOM job wasn't ready after 20 polls |
| `error` | Failed 5 times; the message is in `sbom-work-poison` |

## 5. Onboarding an org

About 30 minutes of CPS time.

1. Confirm the org is covered by `cps-sbom-baseline` and has `cps-sbom-collector` installed. The weekly installer does this for new orgs once Phase 2 is live; to do it now, run `install_collector_on_new_orgs` from the portal.
2. Create the Entra group `sg-sbom-org-<org>` (or add the org to `sbom_orgs` with `manage_entra = true` and apply), assign it to the Dependency-Track enterprise app, and add the team's nominated members.
3. From a machine that can reach the internal API:
   ```bash
   cd sbom-collector
   export DTRACK_URL=$(terraform -chdir=.. output -raw dependency_track_api_url)
   export DTRACK_ADMIN_API_KEY=<a CPS admin key>
   .venv/bin/python ops/dtrack_admin.py onboard-org <org> --teams-webhook <team channel webhook URL>
   ```
   This creates the parent collection project `<org>` (if the collector hasn't already), the team `sg-sbom-org-<org>` mapped to the Entra group, the access entries, and the notification rule.
4. Walk the team lead through their parent project, the audit view, and how to set an analysis state.

The team name **must** be `sg-sbom-org-<org>`, spelled exactly as the GitHub org login. The nightly ACL sync finds teams by that name.

## 6. Terraform repos: `sbom-scan.yml`

GitHub's dependency graph has no Terraform ecosystem, so the collector can't see providers. Terraform repos keep calling the reusable workflow. Every other ecosystem is collected centrally with no repo change.

1. Set the variable `DEPENDENCY_TRACK_URL` (the API URL) and the secret `DEPENDENCY_TRACK_API_KEY` (the `ci-uploader` team's key, Key Vault secret `dtrack-ci-api-key`) on the repo, or once at org level.
2. Copy [`examples/consumer-workflows/ci.yml`](../examples/consumer-workflows/ci.yml) and [`cd.yml`](../examples/consumer-workflows/cd.yml).
3. The job needs a runner with a route to the internal Dependency-Track (`cps-ubuntu-latest-private`).

`npm` is still accepted as `sbom_type`, but the collector already covers npm through the dependency graph, so use it only where a repo needs a CI-time SBOM.

Inspect a Terraform SBOM locally:
```bash
npx --yes @cyclonedx/cdxgen@10 -t terraform -o bom.json .
jq -r '.components[] | "\(.name) \(.version)"' bom.json
```

## 7. Container images and Bicep repos

**Image components in the inventory (Phase 3).** Call [`container-sbom.yml`](../.github/workflows/container-sbom.yml) from the default-branch build with the image digest. Syft submits the image SBOM to the dependency submission API, and the collector picks it up the next night. See [`examples/consumer-workflows/container-image.yml`](../examples/consumer-workflows/container-image.yml).

**Release-time attested SBOMs (Phase 3).** [`release-sbom-attest.yml`](../.github/workflows/release-sbom-attest.yml) signs the release SBOM with an attestation bound to the image digest. Verify it with:
```bash
gh attestation verify oci://<image>@<digest> --owner <org> --predicate-type https://spdx.dev/Document/v2.3
```

**Image CVEs in GHAS.** [`image-scan.yml`](../.github/workflows/image-scan.yml) runs Trivy against an explicit image list and uploads SARIF to the repo's Security tab. The caller must grant `security-events: write`. It never fails a job on findings.

**Bicep.** A Bicep file has no package-manager dependencies, so there is no SBOM to collect. Keep Checkov/PSRule for misconfiguration.
- For registry-published Bicep modules, the control is provenance: pin to a digest, restrict trusted registries, and review in PR.
- For container images a template references, use the two workflows above.

## 8. Running the collector

- **Run enumeration now:** Portal → `func-sbom-<env>` → `enumerate_repos` → Test/Run, or `az rest` against the admin endpoint.
- **Force a repo:** delete its row from the `repostate` table; the next enumeration queues it.
- **Rate limits:** `generate-report` has its own GitHub limit (`dependency_sbom`). Throttled jobs are parked on the queue until the limit resets, so a large backlog drains over hours. The limit is 100 an hour per org, about 2,400 repos a night, so only an org larger than that needs more than one night for its first collection. That is expected, not a failure.
- **Logs:** Application Insights `appi-sbom-<env>`, and `FunctionAppLogs` in the CPS workspace.
- **Local run:** [`poc/README.md`](../poc/README.md) runs the collector against real GitHub, with Dependency-Track and Azurite in Docker and no Azure needed.
- **Tests:** `cd sbom-collector && .venv/bin/python -m pytest -q`. For Terraform: `terraform init -backend=false && terraform test`.

## 9. Rotating credentials

| Credential | Where | How |
|---|---|---|
| `cps-sbom-collector` private key | Key Vault `github-app-private-key` | Every 6 months: add a second key in the App settings, `az keyvault secret set --file`, restart the Function App, then delete the old key in GitHub |
| `cps-app-installer` private key | Key Vault `github-installer-private-key` | Same as above |
| Collector upload key | Key Vault `dtrack-api-key` (team `bom-uploader`) | Dependency-Track → Administration → Teams → `bom-uploader` → API Keys → regenerate; update the secret; restart the Function App |
| ACL sync key | Key Vault `dtrack-acl-key` (team `acl-sync`) | As above |
| CI upload key | Key Vault `dtrack-ci-api-key` → GitHub secret `DEPENDENCY_TRACK_API_KEY` | Regenerate, update both places |
| Postgres admin password | Key Vault `postgres-admin-password` (Terraform-generated) | `terraform apply -replace=random_password.postgres_admin`. This restarts Dependency-Track with the new password; expect a brief outage |

The collector caches secrets for the life of an instance; restart after any rotation.

## 10. Failure runbook

| Symptom | Likely cause | Fix |
|---|---|---|
| **Poison-queue alert** (`sbom-poison-queue-not-empty`) | GitHub 5xx, a malformed SBOM, or Dependency-Track down | Find the repo's `error` row in `GitHubSbomRun_CL` (Detail has the exception) and the App Insights exception. Fix the cause, then move the message back to `sbom-work` (Storage Explorer), or delete its `repostate` row so the next run re-queues it. |
| **`sbom-enumerate-not-succeeded` alert** | Bad or rotated private key, App uninstalled, Function host down | Check `enumerate_repos` failures in App Insights. A 401 on `access_tokens` means the wrong key in `github-app-private-key`: update it and restart the Function App. |
| HTTP 401 creating installation tokens | Private key rotated or wrong in Key Vault | Update `github-app-private-key`; restart the Function App |
| HTTP 404 on every repo in an org | Collector not installed on that org, or set to selected repos | Run `install_collector_on_new_orgs` (it also switches "selected" to "all"), or fix the installation by hand |
| Many `no-dependency-graph` rows for one org | Org outside `cps-sbom-baseline`, or no manifests | Check the configuration's coverage; repos with no manifests are expected |
| Many `timeout` rows | GitHub's async SBOM jobs are slow | Check githubstatus.com; raise the 20-poll cap in `function_app.py` if it persists |
| Backlog in `sbom-work` that drains slowly | `dependency_sbom` rate limit | Expected after a full refresh or a new large org; see §8 |
| A team can't see a repo they own | ACL sync hasn't run since the project appeared, or no team named `sg-sbom-org-<org>` | Wait for 04:30 UTC or run `dtrack_admin.py sync-acl`; check the `No Dependency-Track team for org(s)` warning in App Insights |
| Collector fails with "parent project … not visible to this API key" | The org parent was created by someone else and `bom-uploader` isn't on its ACL | `dtrack_admin.py onboard-org <org>` or `sync-acl` |
| Dependency-Track slow or out of memory | Portfolio grew past 8 GiB container memory | Move `ca-dtrack-api` to a Dedicated workload profile with more memory (add a `workload_profile` block in `dependency_track.tf`) |
| Sentinel rows missing, no errors | Role on the DCR missing, or schema mismatch | Check Monitoring Metrics Publisher on `dcr-sbom-<env>`. The table and DCR columns come from one list in `sentinel.tf`, so a mismatch means someone changed the table by hand. |
| `sbom-scan.yml` upload fails to connect | Runner has no route to the internal Dependency-Track | Use `cps-ubuntu-latest-private`, or ask the landing-zone team for the route and DNS forwarding |
