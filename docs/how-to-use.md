# How to use — CPS SBOM platform (Dependency-Track)

This guide covers day-to-day use of the platform, the Terraform CI path, container images, and what to do when something breaks. *Why* it is built this way: [ADR-0001](adr/0001-team-sbom-platform.md). *Deploying it*: [deployment runbook](deployment-runbook.md).

**Data classification: OFFICIAL-SENSITIVE.** An SBOM lists every library and version a service runs, which tells an attacker where to aim. Access by named group only, and no export outside the platform without CPS sign-off.

---

## Table of contents

1. [Where things live](#1-where-things-live)
2. [Operating model](#2-operating-model)
3. [Dependency-Track](#3-dependency-track)
4. [Terraform repos: `sbom-scan.yml`](#4-terraform-repos-sbom-scanyml)
5. [Collector statuses](#5-collector-statuses)
6. [Running the collector](#6-running-the-collector)
7. [Rotating credentials](#7-rotating-credentials)
8. [Failure runbook](#8-failure-runbook)
9. [Container images and Bicep repos](#9-container-images-and-bicep-repos)

---

## 1. Where things live

```
GitHub CPS org  ── dependency graph on every repo (cps-sbom-baseline)
   │  cps-sbom-collector App (org-owned, read-only)
   ▼
func-sbom-<env>  enumerate_repos 02:00 UTC → sbom-work queue → collect_sbom
   │  report_poison_depth every 15 min
   ├─► Blob   stsbom<env>/sbom-raw/<org>/<repo>/<date>.spdx.json   history, 13 months
   └─► Dependency-Track  <org>/<repo> under parent <org>           findings are worked here
```

Get the URLs with `terraform output dependency_track_url` (UI) and `dependency_track_api_url` (API). The UI only opens from `allowed_ip_ranges`.

**Default branch only.** The SBOM shows what is on each repo's default branch, which is not necessarily what is deployed. Release-time attested SBOMs (§9) close that gap for services that adopt them.

## 2. Operating model

| Activity | CPS platform | CPS security | Repo owner |
|---|---|---|---|
| Run the collector and Dependency-Track | R/A | C | I |
| Org security configuration (`cps-sbom-baseline`) | R/A | C | I |
| Triage findings in a repo | I | C | R/A |
| Set vulnerability and licence policies | C | R/A | C |
| Incident lookup ("where is package X") | C | R/A | C |
| Access reviews of the two Entra groups (quarterly) | R | A | I |

| Service level | Level |
|---|---|
| Collection | Nightly. Changed repos no older than 24 hours; every repo no older than 7 days (rolling refresh) |
| Critical finding triage by the repo owner | 5 working days |
| Dependency-Track patching | Within 30 days of a new 4.x release; **within 7 days for a security release**, because the API is internet-facing |

Policies are **warn only** for the first three months. Nothing here blocks a build.

## 3. Dependency-Track

Sign in with your Entra account. Members of `sg-sbom-cps-users` see every project and can triage; members of `sg-sbom-cps-admins` can also change teams, policies and configuration.

| Project | Version | From |
|---|---|---|
| `<org>` | — | Parent collection project: rolls up the metrics of its children |
| `<org>/<repo>` | default branch | The nightly collector (GitHub dependency graph) |
| `<org>/<repo>/terraform` | `main` or `pr-<n>` | `sbom-scan.yml` in the repo's CI (Terraform providers) |

- **Vulnerabilities**: matched continuously against NVD, GitHub Advisories and OSV. A CVE published next month shows up on today's SBOM without re-collecting.
- **Audit**: set an *analysis state* (exploitable, not affected, false positive, …) with a justification. That is the triage record.
- **Policy violations**: the starter policies are critical/high vulnerability (warn), restricted or unknown licence in a project tagged `distributed` (warn), and component 3+ major versions behind (info). Tag a project `distributed` if the service ships outside CPS.
- **Notifications**: new vulnerabilities and policy violations go to the Teams channel, if `onboard-org` was given `--teams-webhook`.

**Incident lookup: where do we use package X?**

- **By package:** UI → Components → search by name (`log4j-core`) or by purl. Each result links to its project.
- **By CVE:** UI → Vulnerabilities → search the ID → *Affected Projects*.
- **From the CLI**, with any API key that has VIEW_PORTFOLIO:
  ```bash
  curl -s -H "X-Api-Key: $KEY" "$DT_API/api/v1/component/identity?name=log4j-core" \
    | jq -r '.[] | "\(.project.name)\t\(.name)\t\(.version)"'
  curl -s -H "X-Api-Key: $KEY" "$DT_API/api/v1/vulnerability/source/NVD/vuln/CVE-2021-44228/projects" \
    | jq -r '.[].name'
  ```

Package names are the names GitHub's SBOM uses, for example `@azure/core-rest-pipeline`, `actions/checkout`, `log4j-core`. Use the purl to be exact.

## 4. Terraform repos: `sbom-scan.yml`

GitHub's dependency graph has no Terraform ecosystem, so the collector can't see providers. Terraform repos keep calling the reusable workflow. Every other ecosystem is collected centrally with no repo change.

1. Set the variable `DEPENDENCY_TRACK_URL` (the API URL) and the secret `DEPENDENCY_TRACK_API_KEY` (the `ci-uploader` team's key, Key Vault secret `dtrack-ci-api-key`) once at org level. See [runbook step 15](deployment-runbook.md#step-15--test-the-terraform-path-sbom-scanyml).
2. Copy [`examples/consumer-workflows/ci.yml`](../examples/consumer-workflows/ci.yml) and [`cd.yml`](../examples/consumer-workflows/cd.yml).

`npm` is still accepted as `sbom_type`, but the collector already covers npm through the dependency graph, so use it only where a repo needs a CI-time SBOM.

Inspect a Terraform SBOM locally:
```bash
npx --yes @cyclonedx/cdxgen@10 -t terraform -o bom.json .
jq -r '.components[] | "\(.name) \(.version)"' bom.json
```

## 5. Collector statuses

Every repo the collector handles gets one `sbom-result` line in Application Insights `appi-sbom-<env>`. It also gets a row in the `repostate` table, holding the last status. [`collector-status.kql`](../sbom-collector/kql/collector-status.kql) summarises the latest status per repo.

| Status | Meaning |
|---|---|
| `ok` | SBOM collected and loaded |
| `skipped` | Archived, disabled or empty repo |
| `no-dependency-graph` | GitHub returned 404: no manifests, or the repo isn't under `cps-sbom-baseline` |
| `timeout` | GitHub's SBOM job wasn't ready after 20 polls |
| `error` | Failed 5 times; the message is in `sbom-work-poison` |

To find one repo's last result:

```kusto
traces
| where message startswith "sbom-result " and message has '"Repo": "<repo>"'
| top 5 by timestamp
```

## 6. Running the collector

- **Run enumeration now:** Portal → `func-sbom-<env>` → `enumerate_repos` → Test/Run, or the `curl` in [runbook step 14](deployment-runbook.md#step-14--run-the-first-collection).
- **Force a repo:** delete its row from the `repostate` table; the next enumeration queues it.
- **Rate limits:** `generate-report` has its own GitHub limit (`dependency_sbom`) of 100 an hour per org. Throttled jobs are parked on the queue until the limit resets, so a large backlog drains over hours. That is expected, not a failure.
- **Logs:** Application Insights `appi-sbom-<env>`, and `FunctionAppLogs` in `log-sbom-<env>`.
- **Local run:** [`poc/README.md`](../poc/README.md) runs the collector against real GitHub, with Dependency-Track and Azurite in Docker and no Azure needed.
- **Tests:** `cd sbom-collector && .venv/bin/python -m pytest -q`. For Terraform: `terraform init -backend=false && terraform test`.

## 7. Rotating credentials

| Credential | Where | How |
|---|---|---|
| `cps-sbom-collector` private key | Key Vault `github-app-private-key` | Every 6 months: add a second key in the App settings, `az keyvault secret set --file`, restart the Function App, then delete the old key in GitHub |
| Collector upload key | Key Vault `dtrack-api-key` (team `bom-uploader`) | Dependency-Track → Administration → Teams → `bom-uploader` → API Keys → regenerate; update the secret; restart the Function App |
| CI upload key | Key Vault `dtrack-ci-api-key` → GitHub secret `DEPENDENCY_TRACK_API_KEY` | Regenerate, update both places |
| Local admin password | Key Vault `dtrack-admin-password` | Only needed while `admin` is unsuspended; change it in the UI and update the secret |
| Postgres admin password | Key Vault `postgres-admin-password` (Terraform-generated) | `terraform apply -replace=random_password.postgres_admin`. This restarts Dependency-Track with the new password; expect a brief outage |

The collector caches secrets for the life of an instance; restart after any rotation. Because the API is internet-facing, rotate an API key at once if it may have leaked.

## 8. Failure runbook

| Symptom | Likely cause | Fix |
|---|---|---|
| **Poison-queue alert** (`sbom-poison-queue-not-empty`) | GitHub 5xx, a malformed SBOM, or Dependency-Track down | Find the repo's `error` line (§5; `Detail` has the exception) and the App Insights exception. Fix the cause, then move the message back to `sbom-work` (Storage Explorer), or delete its `repostate` row so the next run re-queues it. |
| **`sbom-enumerate-not-succeeded` alert** | Bad or rotated private key, App uninstalled, Function host down | Check `enumerate_repos` failures in App Insights. A 401 on `access_tokens` means the wrong key in `github-app-private-key`: see the next row. |
| HTTP 401 creating installation tokens | Private key rotated or wrong in Key Vault | Update `github-app-private-key`; restart the Function App |
| HTTP 404 on every repo | App uninstalled, or installed on selected repositories | Org → Settings → GitHub Apps → `cps-sbom-collector` → Configure → **All repositories** |
| Many `no-dependency-graph` results | Repos outside `cps-sbom-baseline`, or no manifests | Check the configuration's repository list; repos with no manifests are expected |
| Many `timeout` results | GitHub's async SBOM jobs are slow | Check githubstatus.com; raise the 20-poll cap in `function_app.py` if it persists |
| Backlog in `sbom-work` that drains slowly | `dependency_sbom` rate limit | Expected after a refresh of many repos; see §6 |
| Collector fails with "parent project … not visible to this API key" | Portfolio access control was turned on | Turn it off (Administration → Access Management → Portfolio Access Control), or re-run `dtrack_admin.py bootstrap`, which turns it off |
| Dependency-Track UI returns 403 | Your IP isn't in `allowed_ip_ranges` | Add the CIDR to the tfvars and apply |
| Dependency-Track slow or out of memory | Portfolio grew past 8 GiB container memory | Move `ca-dtrack-api` to a Dedicated workload profile with more memory (add a `workload_profile` block in `dependency_track.tf`); move Postgres to `GP_Standard_D2ds_v5` |
| `sbom-scan.yml` upload fails with 401 or 403 | Wrong or rotated `DEPENDENCY_TRACK_API_KEY` | Copy `dtrack-ci-api-key` to the GitHub secret again |

## 9. Container images and Bicep repos

**Image components in the inventory (optional).** Call [`container-sbom.yml`](../.github/workflows/container-sbom.yml) from the default-branch build with the image digest. Syft submits the image SBOM to the dependency submission API, and the collector picks it up the next night. See [`examples/consumer-workflows/container-image.yml`](../examples/consumer-workflows/container-image.yml).

**Release-time attested SBOMs (optional).** [`release-sbom-attest.yml`](../.github/workflows/release-sbom-attest.yml) signs the release SBOM with an attestation bound to the image digest. Verify it with:
```bash
gh attestation verify oci://<image>@<digest> --owner <org> --predicate-type https://spdx.dev/Document/v2.3
```

**Image CVEs in GHAS.** [`image-scan.yml`](../.github/workflows/image-scan.yml) runs Trivy against an explicit image list and uploads SARIF to the repo's Security tab. The caller must grant `security-events: write`. It never fails a job on findings.

**Bicep.** A Bicep file has no package-manager dependencies, so there is no SBOM to collect. Keep Checkov/PSRule for misconfiguration.
- For registry-published Bicep modules, the control is provenance: pin to a digest, restrict trusted registries, and review in PR.
- For container images a template references, use the workflows above.
