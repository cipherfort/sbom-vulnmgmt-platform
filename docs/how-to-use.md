# How to Use — Security Platform (Dependency-Track + DefectDojo)

This guide covers day-to-day use of the platform, how to onboard another repo, and how Bicep repos are handled differently from Terraform/npm ones. For *why* this platform was chosen, see [`docs/adr/0001-sbom-and-vulnerability-management-platform.md`](adr/0001-sbom-and-vulnerability-management-platform.md). For deploying the platform itself, see the root [`README.md`](../README.md).

**GHAS Enterprise note:** Checkov and Trivy findings are dual-written (see ADR-0001) — SARIF goes to both GitHub's native Security tab *and* DefectDojo. DefectDojo is the single pane across every repo and finding type; GHAS's tab is a secondary, per-repo, PR-native view of the same SARIF-sourced findings, not a second source of truth. This guide reflects that throughout.

---

## Table of contents

1. [Platform overview — where things live](#1-platform-overview--where-things-live)
2. [Using Dependency-Track day to day](#2-using-dependency-track-day-to-day)
3. [Using DefectDojo day to day](#3-using-defectdojo-day-to-day)
4. [Onboarding a new repo — step by step](#4-onboarding-a-new-repo--step-by-step)
5. [How Bicep repos are treated](#5-how-bicep-repos-are-treated)
6. [Generating and inspecting an SBOM locally](#6-generating-and-inspecting-an-sbom-locally)
7. [Rotating credentials](#7-rotating-credentials)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Platform overview — where things live

```
Dependency-Track           https://<dtrack-frontend-url>          "is this component vulnerable?"
  └─ apiserver              https://<dtrack-apiserver-url>         (what CI actually talks to)

DefectDojo                 https://<defectdojo-url>                "who owns fixing it, by when?"

Both hosted in this repo's Terraform, on Azure Container Apps.
Get the real URLs with:  terraform output dependency_track_url / dependency_track_api_url / defectdojo_url
```

**One rule of thumb for where to work:** Dependency-Track tells you *whether* something is vulnerable and keeps that answer current automatically. DefectDojo is where a human decides *what to do about it*. Don't triage inside Dependency-Track — findings live there only long enough to get exported into DefectDojo.

---

## 2. Using Dependency-Track day to day

### Projects

Every onboarded repo becomes one or more **Projects**, named after the repo, versioned by branch:

| Project name | Project version | Created by |
|---|---|---|
| `azure-policy-as-code-terraform` | `main` | `cd.yml`, on every push to `main` |
| `azure-policy-as-code-terraform` | `pr-142` | `ci.yml`, on PR #142 |

PR-versioned projects accumulate over time (one per PR number). This is intentional — it lets you compare a PR's dependency set against `main` before merging. There's no automatic cleanup yet; if the project list gets noisy, delete old `pr-*` projects manually (Projects → select → Delete) — this is safe, `main` is unaffected.

### Reading a project

Open a project → you'll see:
- **Components** tab — every Terraform provider (or npm package, for the LZA repo) at the exact version `cdxgen` found in the repo, pulled straight from `bom.json`
- **Vulnerabilities** tab — anything Dependency-Track matched between those components and NVD/GitHub Advisories/OSV, with severity
- **Dependency Graph** — usually flat for Terraform (providers don't have deep transitive trees the way npm does); more useful on the LZA repo

### Why you don't need to re-scan

Once a project exists, Dependency-Track re-checks its components against vulnerability feeds on its own schedule — a CVE disclosed next month against `hashicorp/azurerm` 4.69.0 will show up on the existing `main` project without CI running again. CI's job is only to keep the *component list* current (a new SBOM upload on every push replaces it); Dependency-Track's job is to keep the *vulnerability match* current continuously.

### Teams and API keys (needed once, during platform setup)

Administration → Access Management → Teams → create or use a team → **Permissions**, grant at least:
- `BOM_UPLOAD` — required for CI to push SBOMs
- `PROJECT_CREATION_UUID` — required for `autocreate: true` in the upload action to work
- `VIEW_PORTFOLIO` — required for the `defectdojo-import` job's project lookup
- `VIEW_VULNERABILITY` — required for the `defectdojo-import` job's finding export; a key with only `VIEW_PORTFOLIO` can find the project but gets a 403 from `/api/v1/finding/project/{uuid}/export`

Then **API Keys** on that same team → generate → this is the value for the `DEPENDENCY_TRACK_API_KEY` secret in every onboarded repo. (Permission names above are current as of the image tag pinned in `variables.tf` — double-check against your instance's Administration UI if they've been renamed since.)

---

## 3. Using DefectDojo day to day

DefectDojo is the **single pane across every onboarded repo and finding type**: Dependency-Track's findings (Terraform/npm CVEs), plus Checkov and Trivy findings dual-written here alongside GitHub's own Security tab (see ADR-0001). If a finding exists anywhere in this platform, it's here — GHAS's Security tab is a secondary, per-repo view of the SARIF-sourced subset, not a place with findings DefectDojo lacks.

### Products and Engagements

One **Product** per repo (e.g. `Azure Policy as Code`), one **Engagement** per import (named `cd-<git-sha>`). This mirrors the "one Dependency-Track project per branch" idea, but at the DefectDojo layer it's "one engagement per deploy" — so you can see exactly which commit a finding was first observed on.

### Triaging a finding

Findings list → filter by Product, severity, or status. For each finding you'd typically:
1. Open it, read the description (Dependency-Track's CVE detail carries through — CVE ID, CVSS score, affected version range)
2. Set a status: **Active** (needs fixing), **Verified** (a human confirmed it's real), **False Positive**, **Risk Accepted** (documented and accepted, e.g. no fixed version exists yet and the risk is low), **Mitigated** (fixed by something other than a version bump), or **Duplicate**
3. Assign it to whoever owns that repo
4. If your DefectDojo instance has SLA settings configured (Product Type → SLA configuration), severity determines the due date automatically

### close_old_findings

The import job passes `close_old_findings=true` — each new import automatically closes findings from a *previous* import on the same engagement that no longer appear (e.g. you bumped the vulnerable provider and it's genuinely gone). You don't need to manually close resolved findings.

### Reports

Product → Reports lets you export a PDF/CSV of current findings — useful for the kind of audit evidence SBOM programs usually exist to produce in the first place.

---

## 4. Onboarding a new repo — step by step

This assumes the platform is already deployed (root `README.md` bootstrap) and you have its URLs and API keys.

### Step 1 — Add repo secrets and variables

In the repo being onboarded, Settings → Secrets and variables → Actions:

| Type | Name | Value |
|---|---|---|
| Variable | `DEPENDENCY_TRACK_URL` | the apiserver URL (`terraform output dependency_track_api_url` in this repo) |
| Variable | `DEFECTDOJO_URL` | `terraform output defectdojo_url` |
| Variable | `DEFECTDOJO_PRODUCT_NAME` | pick a name for this repo's DefectDojo product |
| Variable | `DEFECTDOJO_PRODUCT_TYPE_NAME` | an existing (or new) DefectDojo Product Type — only needed until the product above exists for the first time; every DefectDojo product needs one to be auto-created under |
| Secret | `DEPENDENCY_TRACK_API_KEY` | from Dependency-Track, see §2 |
| Secret | `DEFECTDOJO_API_KEY` | from the target user's DefectDojo API v2 Key page |

### Step 2 — Call the reusable workflow

Add a job to that repo's CI workflow (PR-triggered) and CD workflow (push-to-default-branch-triggered):

```yaml
jobs:
  sbom-scan:
    uses: sg-cloud-platform/cps-security-platform-infra/.github/workflows/sbom-scan.yml@main
    with:
      sbom_type: terraform                              # or: npm — see step 3
      project_name: ${{ github.event.repository.name }}
      project_version: pr-${{ github.event.pull_request.number }}   # "main" on the CD workflow
      dependency_track_url: ${{ vars.DEPENDENCY_TRACK_URL }}
      defectdojo_url: ${{ vars.DEFECTDOJO_URL }}
      defectdojo_product_name: ${{ vars.DEFECTDOJO_PRODUCT_NAME }}
      defectdojo_product_type_name: ${{ vars.DEFECTDOJO_PRODUCT_TYPE_NAME }} # only needed until the product exists — see step 1
      import_to_defectdojo: false                        # true only on the CD/main-branch call — see step 3
    secrets:
      dependency_track_api_key: ${{ secrets.DEPENDENCY_TRACK_API_KEY }}
      defectdojo_api_key: ${{ secrets.DEFECTDOJO_API_KEY }}
```

This is exactly what `azure-policy-as-code-terraform`'s `ci.yml`/`cd.yml` do today, just inlined there instead of called as a reusable workflow (it was the pilot — wired inline first, extracted here second). New repos should use the `uses:` form above rather than copy-pasting the inline steps.

### Step 3 — Pick `sbom_type` and the DefectDojo import point

| Repo kind | `sbom_type` | Notes |
|---|---|---|
| Terraform | `terraform` | Reads `.terraform.lock.hcl` + provider requirement blocks |
| npm / CDK (e.g. AWS Landing Zone Accelerator) | `npm` | Needs a `package-lock.json` committed — `cdxgen` reads it to resolve exact resolved versions, not just the ranges in `package.json` |
| Bicep | — not onboarded — | See [§5](#5-how-bicep-repos-are-treated) |

Set `import_to_defectdojo: true` **only** on the call from the default-branch/CD workflow, not from the PR-triggered one. Findings tracking should reflect what's actually deployed, not every open PR branch — otherwise DefectDojo fills up with findings for code that may never merge.

### Step 4 — Verify the first run

1. Open a PR on the newly onboarded repo → confirm the `sbom-scan` job runs and a `bom.json` artifact appears
2. Check Dependency-Track → a project named after the repo, version `pr-<number>`, should appear with populated components within a few minutes
3. Merge to the default branch → confirm a `main`-versioned project appears in Dependency-Track, and (once it finishes processing) a corresponding Product/Engagement appears in DefectDojo

### Step 5 — Adapting to a repo's existing CI/CD shape

Steps 1–4 assume a repo shaped like the pilot (`azure-policy-as-code-terraform`): a separate PR-triggered workflow and merge-triggered workflow. Not every future repo will look like that — here's how to fit the same two jobs into whatever shape a given repo actually has.

**Repo has separate PR and merge workflows** — the case Steps 1–4 already cover. Add the job to both; `import_to_defectdojo: false` on the PR one, `true` on the merge one. This is the pattern in `azure-policy-as-code-terraform`'s `ci.yml`/`cd.yml` — worth opening those two files side by side with a new repo's equivalents as a working reference.

**Repo has one combined workflow triggered on both `pull_request` and `push`** — don't duplicate the job; branch its inputs on `github.event_name` instead:
```yaml
jobs:
  sbom-scan:
    uses: sg-cloud-platform/cps-security-platform-infra/.github/workflows/sbom-scan.yml@main
    with:
      sbom_type: terraform
      project_name: ${{ github.event.repository.name }}
      project_version: ${{ github.event_name == 'push' && 'main' || format('pr-{0}', github.event.pull_request.number) }}
      import_to_defectdojo: ${{ github.event_name == 'push' }}
      dependency_track_url: ${{ vars.DEPENDENCY_TRACK_URL }}
      defectdojo_url: ${{ vars.DEFECTDOJO_URL }}
      defectdojo_product_name: ${{ vars.DEFECTDOJO_PRODUCT_NAME }}
    secrets:
      dependency_track_api_key: ${{ secrets.DEPENDENCY_TRACK_API_KEY }}
      defectdojo_api_key: ${{ secrets.DEFECTDOJO_API_KEY }}
```

**Repo has a per-environment deployment matrix** (like the pilot's `detect-changes` → `terraform-plan`/`terraform` matrix, one plan/apply per management group) — the SBOM job describes the repo's *dependencies*, not its *deployment targets*. It runs **once**, as a job sibling to the matrix job, never nested inside `strategy.matrix` — a repo with 5 environments should still produce exactly one SBOM per commit, not five identical ones.

**Repo is the AWS Landing Zone Accelerator (CDK/npm)** — mechanically identical to a Terraform repo, just `sbom_type: npm` instead of `terraform`, and it needs `package-lock.json` committed (see §4, Step 3). Slot the job in alongside whatever `cdk synth`/`cdk diff`/`cdk deploy` steps that repo's pipeline already has; there's no interaction between them — it's an independent job like Checkov is in the pilot's `ci.yml`.

### Step 6 — GitHub-native coverage: Dependabot alerts (optional)

`sbom-scan.yml` covers Terraform/npm dependencies, and `image-scan.yml` (§5b) covers container images — but neither sees a risk GitHub's own dependency graph already tracks for you, most notably a compromised or vulnerable **pinned GitHub Actions version** (the kind of supply-chain incident that's hit widely-used actions before). GitHub surfaces this as a Dependabot alert automatically; [`.github/workflows/dependabot-import.yml`](../.github/workflows/dependabot-import.yml) just pulls those alerts into DefectDojo so they show up in the same single pane as everything else, instead of only being visible in each repo's own Security tab.

This intentionally bypasses Dependency-Track — GitHub's own SBOM export is SPDX format, and Dependency-Track only ingests CycloneDX, so there's no clean path through it. DefectDojo has a purpose-built `Github Vulnerability Scan` importer that consumes GitHub's Dependabot-alerts GraphQL response directly, so that's the route this workflow takes.

Applies to any repo, not just Terraform/npm ones — add it independently of `sbom_type`:

```yaml
jobs:
  dependabot-import:
    permissions:
      security-events: read   # required — GITHUB_TOKEN can't read Dependabot alerts without this
    uses: sg-cloud-platform/cps-security-platform-infra/.github/workflows/dependabot-import.yml@main
    with:
      defectdojo_url: ${{ vars.DEFECTDOJO_URL }}
      defectdojo_product_name: ${{ vars.DEFECTDOJO_PRODUCT_NAME }}
      defectdojo_product_type_name: ${{ vars.DEFECTDOJO_PRODUCT_TYPE_NAME }}  # only needed until the product exists — see §4, Step 1
    secrets:
      defectdojo_api_key: ${{ secrets.DEFECTDOJO_API_KEY }}
```

Same `security-events` permission-passthrough rule as `image-scan.yml` (§5b, step 3) applies: the reusable workflow declaring `permissions: security-events: read` in its own job isn't enough by itself — the *calling* job must grant it too, or the Dependabot-alerts fetch 403s. Run this on a schedule or on the default-branch push, not every PR — alert state doesn't change per-PR, so there's nothing to gain from running it more often.

### Pin the reusable workflow reference deliberately, once past the pilot

Every example above uses `@main`. That's the right choice while this platform is a single pilot repo being proven out — but once several repos depend on `sbom-scan.yml`/`image-scan.yml`/`dependabot-import.yml`, a change to any of them on `main` changes behavior in every consuming repo simultaneously, with no warning and no chance to test it against one repo first. Once onboarding moves past the pilot:

- Tag releases of this repo (`v1`, `v2`, ...) and have new consumers reference `@v1` instead of `@main`
- Bump each consumer's pin deliberately when you cut a new tag, rather than letting every repo silently pick up whatever's newest on `main`
- A commit SHA (`@<sha>`) is the strictest possible pin, if a specific repo needs zero drift and you're willing to update that pin by hand

---

## 5. How Bicep repos are treated

**Short answer: they're not onboarded to this pipeline, on purpose.** Continue relying on Checkov (or PSRule for Azure, if you use it) for Bicep repos' risk coverage.

**Why:** SBOM/SCA answers "is a *dependency* of this code vulnerable?" A Bicep file doesn't have dependencies in that sense — no package manager, no lockfile, no resolvable version tree for `cdxgen` (or any other SBOM generator) to walk. Running an SBOM tool against a Bicep repo either produces an empty/meaningless BOM or requires bespoke tooling that doesn't exist yet. The actual risk in a Bicep repo — a misconfigured resource, an overly permissive role assignment — is exactly what Checkov already catches.

Bicep has two things that *do* carry real risk, and each gets a different treatment:

### 5a. Registry-published Bicep modules — provenance, not a scanner

If a repo pulls third-party or externally-maintained Bicep modules (private ACR registry, the public Bicep registry, or a Template Spec), that's genuine supply-chain exposure — you're trusting someone else's template — even though it's not a CVE-tracked "component" the way an npm package or Terraform provider is. There's no CVE database for Bicep modules, so no scanner helps here. The control is provenance: pin modules to a specific digest/version, restrict which registries are trusted, and review module source changes in PR like any other code change.

### 5b. Container images referenced from the template — real CVE data, covered by a separate workflow

If a Bicep repo deploys workloads that reference a container image (Container Apps, AKS, App Service containers, Container Instances), that image has real, trackable CVEs — this is exactly the risk cdxgen/Dependency-Track can't see but a container-image scanner can. That's what [`.github/workflows/image-scan.yml`](../.github/workflows/image-scan.yml) is for: it runs Trivy against a list of image references and **dual-writes** the results as SARIF — to **your repo's own GitHub Security tab** (native, free, PR annotations) and to **DefectDojo** (so it stays the single pane — see ADR-0001).

**Onboarding a Bicep repo to image scanning:**

1. Identify the image references your Bicep templates use — check every resource with an `image`/`containerImage`-shaped property (`Microsoft.App/containerApps`, `Microsoft.ContainerInstance/containerGroups`, `Microsoft.Web/sites` with a container config, etc.). There's no auto-discovery here on purpose — see the comment at the top of `image-scan.yml` for why.
2. Add the same `DEFECTDOJO_URL`, `DEFECTDOJO_API_KEY`, `DEFECTDOJO_PRODUCT_NAME` secrets/variables as any other onboarded repo (§4, step 1). If any image lives in a private ACR registry, also add `AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID` secrets (same OIDC pattern as everywhere else).
3. Call the workflow — note the caller must grant `security-events: write` itself; a reusable workflow can only use permissions the caller explicitly hands it:
   ```yaml
   jobs:
     image-scan:
       permissions:
         security-events: write
       uses: sg-cloud-platform/cps-security-platform-infra/.github/workflows/image-scan.yml@main
       with:
         image_refs: '["myacr.azurecr.io/myapp:1.4.2","mcr.microsoft.com/dotnet/aspnet:8.0"]'
         acr_login: true                                    # false if every image is public
         acr_name: myacr                                    # omit if acr_login is false
         defectdojo_url: ${{ vars.DEFECTDOJO_URL }}
         defectdojo_product_name: ${{ vars.DEFECTDOJO_PRODUCT_NAME }}
       secrets:
         azure_client_id: ${{ secrets.AZURE_CLIENT_ID }}
         azure_tenant_id: ${{ secrets.AZURE_TENANT_ID }}
         azure_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
         defectdojo_api_key: ${{ secrets.DEFECTDOJO_API_KEY }}
   ```
   Omit `defectdojo_url`/`defectdojo_product_name` (and the `defectdojo_api_key` secret) if a specific repo genuinely shouldn't dual-write — the DefectDojo import step skips silently when the URL is empty, same graceful-degradation pattern as everywhere else in this platform.
4. Unlike the SBOM pipeline, there's no PR-vs-default-branch distinction to worry about here — both the GHAS upload and the DefectDojo import are scoped to whatever branch/PR the job ran on, so running this on every PR is fine (findings show up as PR checks/annotations in GHAS, same as CodeQL, and as a fresh engagement in DefectDojo).
5. This never fails a job on findings (`exit-code: "0"` on the Trivy step) — it's observability-first, same stance as everything else in this platform. Gating on severity is a separate, deliberate decision to make later, via GHAS's own branch-protection rules for code scanning, not something this workflow does itself.

If neither 5a nor 5b applies to a given Bicep repo — no external modules, no container images — Checkov alone is genuinely sufficient and there's nothing further to onboard.

---

## 6. Generating and inspecting an SBOM locally

Terraform repos:
```bash
npx --yes @cyclonedx/cdxgen@10 -t terraform -o bom.json .
```

npm/CDK repos:
```bash
npx --yes @cyclonedx/cdxgen@10 -t npm -o bom.json .
```

Both write a CycloneDX JSON file. Useful things to check before trusting a CI run:
```bash
# list every component and its version
jq -r '.components[] | "\(.name) \(.version)"' bom.json

# component count — a suspiciously low number (e.g. 0-1) usually means
# cdxgen didn't find a lockfile / provider requirements to read
jq '.components | length' bom.json
```

`azure-policy-as-code-terraform` wraps the Terraform command as `make sbom` (see its `Makefile`).

---

## 7. Rotating credentials

| Credential | How to rotate |
|---|---|
| `DEPENDENCY_TRACK_API_KEY` | Dependency-Track → Administration → Access Management → Teams → team → API Keys → regenerate. Update the secret in every consuming repo. |
| `DEFECTDOJO_API_KEY` | DefectDojo → user menu → API v2 Key → regenerate. Update the secret in every consuming repo. |
| Postgres/Redis/DefectDojo secret-key material in Key Vault | These are Terraform-generated (`random_password`). Rotating means changing the resource in Terraform (e.g. `terraform taint random_password.postgres_admin` then `apply`) — this will restart the affected app(s) with a new credential. Do this deliberately, not as a routine task; it causes a brief outage of that component. |

---

## 8. Troubleshooting

### `sbom-scan` job runs but nothing appears in Dependency-Track
Check that `DEPENDENCY_TRACK_URL` and `DEPENDENCY_TRACK_API_KEY` are actually set on the repo (Settings → Secrets and variables). The upload step is designed to silently skip when either is empty — that's deliberate graceful degradation, not a bug, but it means a missing secret produces no error, just no upload.

### Dependency-Track shows the project but the component count stays 0
The API key's team is missing `VIEW_PORTFOLIO`/`BOM_UPLOAD` permission, or the uploaded `bom.json` genuinely has no components (see §6 — check the component count locally before blaming the pipeline).

### `defectdojo-import` job never runs
It's gated on three things: the SBOM upload succeeding, `inputs.import_to_defectdojo == true`, and `DEFECTDOJO_URL` being non-empty. Missing any one of those causes the job to be skipped (not failed) — check which.

### `defectdojo-import` job fails while "waiting for Dependency-Track BOM processing"
This polls `/api/v1/project/lookup?name=...&version=...` — the `project_name`/`project_version` inputs passed to the workflow must **exactly** match what the upload step used. A common cause is passing a different `project_version` between the upload job and this job (e.g. a typo, or forgetting `pr-` prefix consistency).

### DefectDojo import returns a 400
Both `sbom-scan.yml`'s and `dependabot-import.yml`'s import steps already pass `auto_create_context=true`, so a brand-new product/engagement being created for the first time isn't the usual cause anymore. Check the printed response body (both steps now print it on failure instead of just exiting) — the two real causes seen so far: (1) `defectdojo_product_type_name` wasn't set for a genuinely new product (DefectDojo needs a Product Type to file a new product under, even with auto-create on), or (2) the `scan_type` string sent doesn't match your DefectDojo version's registered choices exactly — confirm the exact string against `dojo/tools/<parser>/parser.py`'s `get_scan_types()` in the DefectDojo source at your pinned `defectdojo_image_tag`, don't assume it matches an older or newer version.

### Two Dependency-Track projects for what I think is one repo
Expected if you're comparing a `pr-<number>` project against `main` — see §2. Not expected if you see two `main` projects; that usually means `project_name` drifted (e.g. the repo was renamed on GitHub after onboarding). Fix by aligning `project_name` back to the current repo name and deleting the orphaned project.

### `image-scan.yml`'s "Upload SARIF to GitHub Security tab" step fails
Almost always a missing permission — the calling job must declare `permissions: security-events: write` itself (see §5b, step 3). A reusable workflow can never grant itself more than the caller hands it, regardless of what `image-scan.yml`'s own job-level `permissions:` says.

### `dependabot-import.yml`'s "Fetch open Dependabot alerts" step 403s
Same permission-passthrough rule as `image-scan.yml` above — the *calling* job must declare `permissions: security-events: read` itself, not just the reusable workflow's own job. If it still 403s after that's set correctly, the automatic `GITHUB_TOKEN` genuinely can't read this repo's Dependabot alerts (this wasn't guaranteed by GitHub's docs and needed a real test to confirm either way) — the fallback is a PAT or GitHub App installation token with Dependabot-alerts read access, passed as its own secret instead of relying on `GITHUB_TOKEN`.

### Checkov's SARIF upload in `ci.yml` fails with "file not found"
`bridgecrewio/checkov-action`'s SARIF output path (`results/results_sarif.sarif`) is a convention, not a guarantee across action versions — if this breaks after bumping the pinned `checkov-action` version, check that release's actual output path and update the `sarif_file` input in the "Upload SARIF to GitHub Security tab" step to match.

### Checkov and Trivy findings show up as separate Test Types in DefectDojo, not merged
Expected — DefectDojo's SARIF parser names the Test Type after the tool that produced the SARIF (`runs[].tool.driver.name`), so you'll see "Checkov (SARIF)" and "Trivy (SARIF)" as distinct tests within the same engagement, not one combined list. This is a DefectDojo behavior, not a bug in the import step.

### A finding is dismissed in GHAS but still open in DefectDojo (or vice versa)
Expected, and worth knowing before it causes confusion — the two systems don't sync. DefectDojo is the one to treat as authoritative (see ADR-0001); if a finding needs to be marked resolved, do it in DefectDojo even if it's already been dismissed in GHAS's Security tab.
