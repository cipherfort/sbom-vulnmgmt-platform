# How to use

SBOMs list every library and version a service runs, so treat this data as **OFFICIAL-SENSITIVE**. Give access to named people only, and don't export it outside the platform.

## Dependency-Track

Sign in to the UI; the address is in the summary of the *SBOM Platform Setup* run. The UI only opens from the networks in `allowed_ip_ranges`.

| Project | What it is |
|---|---|
| `<org>` | Parent project, rolling up every repo |
| `<org>/<repo>` | The repo's default branch, collected nightly |
| `<org>/<repo>/terraform` | Terraform providers, from `sbom-scan.yml` |

On the Projects page, tick **Show flat project view** to list every repo, or expand the org project.

- **Vulnerabilities** are matched continuously against NVD, OSV and, if `DT_ADVISORIES_TOKEN` is set, GitHub Advisories. A CVE published next month shows up without re-collecting anything.
- **Triage** happens in a project's Audit tab: set an analysis state (exploitable, not affected, false positive and so on) and a reason.
- **Policies** start as warnings only:
  - a critical or high vulnerability;
  - a restricted or unknown licence, in projects tagged `distributed`;
  - a component 3 or more major versions behind.

### Where do we use package X?

- **By package:** Components → search by name or purl.
- **By CVE:** Vulnerabilities → search the ID → Affected Projects.
- **From the command line**, with an API key that can view the portfolio:
  ```bash
  curl -s -H "X-Api-Key: $KEY" "$DT_API/api/v1/component/identity?name=log4j-core" | jq -r '.[].project.name'
  curl -s -H "X-Api-Key: $KEY" "$DT_API/api/v1/vulnerability/source/NVD/vuln/CVE-2021-44228/projects" | jq -r '.[].name'
  ```

## The collector

`enumerate_repos` runs at 02:00 UTC. It queues the repos that changed since their last good SBOM, plus a rolling seventh of the rest, so every repo is refreshed at least weekly. `collect_sbom` then fetches each SBOM, archives it to Blob and uploads it to Dependency-Track. GitHub allows 100 SBOMs an hour, so a large backlog takes hours to clear. That's expected.

Each repo's result is logged to Application Insights `appi-sbom-<env>`. [`collector-status.kql`](../sbom-collector/kql/collector-status.kql) summarises the latest result per repo.

| Status | Meaning |
|---|---|
| `ok` | Collected and loaded |
| `skipped` | Archived, disabled or empty repo |
| `no-dependency-graph` | GitHub has no graph for the repo: it has no manifests, or `cps-sbom-baseline` isn't applied to it |
| `timeout` | GitHub hadn't built the SBOM after 20 polls; the next run retries it |
| `error` | Failed 5 times; the message is in the `sbom-work-poison` queue |

- **Run it now:** Actions → *SBOM Platform Setup*, with the restart option off.
- **Re-collect one repo:** delete its row from the `repostate` table.

Repos whose last result wasn't `ok` are always retried on the next run.

## Terraform repos

GitHub's dependency graph has no Terraform support, so Terraform repos call [`sbom-scan.yml`](../.github/workflows/sbom-scan.yml). Copy [`examples/consumer-workflows/ci.yml`](../examples/consumer-workflows/ci.yml) and [`cd.yml`](../examples/consumer-workflows/cd.yml). The org-wide variable and secret they need are set up in the [runbook](deployment-runbook.md#optional-terraform-repos).

## Rotating credentials

| Credential | Where it lives | How to rotate it |
|---|---|---|
| GitHub App private key | Key Vault `github-app-private-key` | Every 6 months: generate a new key in the App settings, put it in the `COLLECTOR_APP_PRIVATE_KEY` secret, and run *SBOM Platform Setup*. Then delete the old key in GitHub. |
| Collector API key | Key Vault `dtrack-api-key` | Regenerate it on the `bom-uploader` team in Dependency-Track, update the secret, and restart the Function App |
| CI API key | Key Vault `dtrack-ci-api-key`, and the `DEPENDENCY_TRACK_API_KEY` secret | Regenerate it on the `ci-uploader` team and update both copies |
| Admin password | Key Vault `dtrack-admin-password` | Change it in the UI and update the secret |
| Postgres password | Key Vault `postgres-admin-password` | `terraform apply -replace=random_password.postgres_admin`; Dependency-Track restarts briefly |

The API is reachable from the internet, so rotate an API key straight away if it might have leaked. Patch Dependency-Track within 7 days of a security release by changing `dtrack_image_tag`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Workflow jobs stay *Queued* | No runner with the label in the workflows | Use a label your org has (runbook step 1) |
| `AADSTS700213` at Azure login | The run wasn't from `main`, or the federated credential doesn't match | Run from `main`; the subject must be `repo:<org>/<repo>:ref:refs/heads/main` |
| `AuthorizationFailed` creating a role assignment | The deployer's RBAC Administrator role is missing | Runbook step 2 |
| Apply fails at Postgres with `SkuNotAvailable` | Azure has no capacity for that size in the region right now | Set `postgres_sku` to `B_Standard_B2ms` or `GP_Standard_D2ds_v5`, or try again later. First wait until `az postgres flexible-server list -g $RG` is empty, because the failed server takes a few minutes to go |
| Plan fails because a name is taken | Key Vault, storage, Postgres and Function names are global | Set `global_name_suffix` |
| The Function lists no functions; the org project has no repos | The code wasn't deployed, or was built with the wrong wheels | Run `cd.yml` with `apply`. A `ModuleNotFoundError` in Application Insights means the wrong wheels. |
| The UI returns 403 | Your IP isn't in `allowed_ip_ranges` | Add it to `TF_VARS_JSON` and apply |
| The UI loads, but pages fail | The API is starting or has crashed | `curl $DT_API/api/version`; `az containerapp logs show -g $RG -n ca-dtrack-api --tail 100` |
| `security-config.sh` gets a 403 | The token lacks `admin:org` | `gh auth refresh -h github.com -s admin:org` |
| Every repo is `no-dependency-graph` | The baseline isn't applied, or the App is installed on selected repos only | Run `security-config.sh`; install the App on all repositories |
| **Alert:** `sbom-enumerate-not-succeeded`, or a 401 on `access_tokens` | Wrong App key, App uninstalled, or the Function is down | Update `COLLECTOR_APP_PRIVATE_KEY` and run *SBOM Platform Setup*; check the App installation |
| 403s from GitHub mentioning an IP allow list | The org restricts which IPs can call GitHub | The Function has no fixed IP. Ask an org owner for an exception, or add a NAT gateway. |
| **Alert:** `sbom-poison-queue-not-empty` | A repo failed 5 times | Find its `error` line (the `Detail` column), fix the cause, then delete its `repostate` row |
| Many `timeout` results | GitHub's SBOM jobs are slow | Check githubstatus.com; they're retried the next night |
| "Parent project not visible to this API key" | Portfolio access control was turned on | Turn it off, or run `dtrack_admin.py bootstrap` again |
| Dependency-Track slow or out of memory | The portfolio outgrew 8 GiB | Give `ca-dtrack-api` a bigger workload profile, and Postgres a General Purpose SKU |
| `sbom-scan.yml` upload gets a 401 | `DEPENDENCY_TRACK_API_KEY` is wrong or rotated | Copy `dtrack-ci-api-key` to it again |
