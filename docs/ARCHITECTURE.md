# Architecture

1. [Overview](#1-overview)
2. [Tool landscape and why Dependency-Track + DefectDojo](#2-tool-landscape-and-why-dependency-track--defectdojo)
3. [Architecture in detail](#3-architecture-in-detail)
4. [Why Azure Container Apps](#4-why-azure-container-apps)
5. [Deployment rationale](#5-deployment-rationale)
6. [Rollout approach](#6-rollout-approach)
7. [Security posture and known gaps](#7-security-posture-and-known-gaps)
8. [Related documents](#8-related-documents)

---

## 1. Overview

Most IaC estates have PR-time misconfiguration scanning (Checkov, PSRule, ...) but no mechanism for detecting *vulnerable dependencies* — an outdated Terraform provider, an npm package with a published CVE, a container image with known vulnerabilities baked in. This platform closes that gap: **Dependency-Track** ingests a CycloneDX SBOM per repo and continuously re-scores its components against NVD/GitHub Security Advisories/OSV, feeding **DefectDojo**, which is where a human actually triages and tracks a finding to resolution — across every repo and every finding type (SCA, misconfiguration, container image CVEs), not just one.

It's deliberately **observability-first**: nothing here blocks a PR on day one (aside from whatever misconfiguration scanning you already run). Rolled out through a reusable GitHub Actions workflow, so onboarding any future repo is a one-line change.

### Why this, why now

SBOM production and dependency-vulnerability tracking have become a baseline industry expectation, not just an internal preference:

- **NTIA "minimum elements for an SBOM"** — the baseline definition most tooling (including CycloneDX) targets.
- **CISA supply-chain guidance** — increasingly what security teams point to when asked "can you produce an SBOM for X."
- **Vendor/customer security questionnaires** (SIG, CAIQ, ...) and framework mappings (ISO 27001 Annex A, SOC 2) increasingly ask about dependency vulnerability management and SBOM availability directly.

None of this means you're under a specific external mandate — but the direction of travel makes this a "when," not an "if," and standing it up before an audit or customer questionnaire forces the issue under time pressure is the cheaper path.

### Glossary

| Term | Meaning here |
|---|---|
| **SBOM** | Software Bill of Materials — a machine-readable inventory of everything a piece of software depends on |
| **CycloneDX** | The SBOM format used here (as opposed to SPDX). Dependency-Track is built around it natively, and `cdxgen` produces it directly from Terraform/npm/many other ecosystems |
| **SCA** | Software Composition Analysis — matching an SBOM's components against vulnerability databases, continuously, not just once |
| **CVE / CVSS** | CVE = a published vulnerability's unique identifier. CVSS = its severity score (0–10) |
| **NVD / GHSA / OSV** | The vulnerability databases Dependency-Track cross-references: the National Vulnerability Database, GitHub Security Advisories, and the Open Source Vulnerabilities database |
| **FPF** | "Finding Packaging Format" — Dependency-Track's own JSON export format for findings, which DefectDojo imports natively |
| **Product / Engagement** | DefectDojo's organizing concepts — one Product per repo, one Engagement per import (named after the commit SHA that triggered it) |
| **Finding** | A single tracked issue in DefectDojo — one per vulnerable component/CVE pairing (or, for image scans, per image/CVE pairing) |
| **SLA** | In DefectDojo, a due-date policy attached to a finding based on severity, if configured |
| **OIDC** | OpenID Connect — how GitHub Actions authenticates to Azure without storing a long-lived credential |
| **Managed Identity** | An Azure AD identity attached directly to a resource (here, a Container App) instead of a shared credential — used so each app can read only the Key Vault secrets it needs |

---

## 2. Tool landscape and why Dependency-Track + DefectDojo

| Option | SBOM/SCA depth | Vuln mgmt (ticketing/SLA/dedup) | Multi-scanner aggregation | Cost model | Verdict |
|---|---|---|---|---|---|
| **Dependency-Track + DefectDojo** | Excellent (DT is purpose-built, OWASP flagship) | Excellent (DD's core purpose) | Excellent — DD ingests SAST/DAST/IaC/SCA from ~150 scanner formats | Self-hosted, no license fee | **Recommended** |
| DefectDojo alone (skip DT) | Weak — DD can import an SBOM but doesn't do DT's continuous re-scoring against newly published CVEs | Excellent | Excellent | Self-hosted, no license fee | Rejected — loses continuous monitoring, findings only refresh when a scan is re-run |
| Dependency-Track alone (skip DD) | Excellent | None — no ticketing, no cross-tool dedup, no SLA | None — SCA only | Self-hosted, no license fee | Rejected — leaves the actual "management" half of the problem unsolved |
| Commercial SaaS (Snyk, Mend, JFrog Xray) | Good–excellent | Varies, generally weaker cross-scanner aggregation than DefectDojo | Varies | Per-seat/per-repo licensing, scales with repo count | Rejected/deferred — recurring cost that scales with repo count; data leaves your tenant |
| GitHub Advanced Security / Dependabot, if available to you | Verified against current GitHub docs: **no** Dependency Graph support for Terraform → no security alerts, no native SBOM coverage for it. **Full** support for npm (Dependency Graph, alerts, native SPDX SBOM export) | Native for GitHub-sourced findings (Dependabot/CodeQL/secret scanning) only; also ingests arbitrary SARIF (used for Checkov/Trivy — see below) | Org-wide Security overview aggregates native + SARIF-uploaded findings | Depends on your GitHub plan | **Complementary, not a substitute** — covers Checkov/Trivy (via SARIF) and npm well, but has zero Terraform coverage, which is this platform's core reason to exist |
| Trivy/Grype at scan time only, no persistent platform | Fair | None | None | Free, but point-in-time only | Rejected — no continuous monitoring, no central record, findings live only in a CI log |
| Status quo (misconfiguration scanning only) | None | None | None | — | Rejected — this is the gap being closed |

### Why not just pick one tool?

The natural question is "why run two applications instead of one." The honest answer: no single widely-available tool does both jobs well.

- Dependency-Track's entire design center is "ingest an SBOM once, keep matching it against new CVEs forever." It has no concept of assigning a finding to a person, tracking it against an SLA, or recognizing that the same underlying issue showed up from two different scanners.
- DefectDojo's entire design center is the opposite: it's a triage/ticketing/reporting layer that's deliberately scanner-agnostic — it imports findings from ~150 different tool output formats. It does not itself re-derive "is this dependency vulnerable" on an ongoing basis; it just tracks whatever a scan told it.

Chaining them plays to each tool's actual strength, and DefectDojo's cross-scanner aggregation capability is what makes it the single pane across every scanner in this platform, not just Dependency-Track's.

### If you already have GitHub Advanced Security

Worth checking directly against GitHub's current documentation rather than assuming either way — the coverage splits by ecosystem:

- **Terraform — no overlap at all.** GitHub's Dependabot alerts require the ecosystem to be supported by the Dependency Graph, and Terraform is not a supported Dependency Graph ecosystem — confirmed directly from GitHub's own docs. No alerts, no native SBOM coverage. This is this platform's entire reason to exist, and GitHub's native tooling doesn't touch it.
- **npm — full overlap.** GitHub's Dependabot support for npm is mature: Dependency Graph, security alerts, and native SPDX SBOM export all work today. Keeping an npm repo on this pipeline too, deliberately, buys one consistent place to check across every onboarded repo rather than splitting by repo type — a known, accepted duplication if you choose it, not an oversight.
- **Checkov and Trivy — dual-written to both, if you use it.** Both output SARIF, which GitHub ingests natively into the same Security tab as Dependabot/CodeQL, giving PR-native inline annotations. The same SARIF file is *also* imported into DefectDojo (it has a generic SARIF importer), so DefectDojo holds every finding type for every repo, and GitHub's tab is a convenience view rather than a second source of truth.

### On cost

Get an actual Azure Pricing Calculator estimate for the specific SKUs in your target region before quoting a number to anyone deciding budget — this document deliberately doesn't put one on it. What can be said directionally: every commercial alternative in the table above prices per seat or per repo, so the bill grows every time you onboard another repo. The self-hosted option's marginal cost of onboarding repo #21 is effectively zero — it's the same Dependency-Track/DefectDojo instance ingesting one more SBOM. The cost you carry instead is engineering time for patching and uptime (see [§7](#7-security-posture-and-known-gaps)) — a real cost, just a different shape than a recurring license.

---

## 3. Architecture in detail

### Data flow

```
Path 1 — SBOM (Terraform + npm repos)
GitHub Actions → cdxgen → bom.json (CycloneDX)
    → Dependency-Track (continuously re-scores against NVD/GHSA/OSV;
      this is the coverage GitHub's native tooling cannot provide for
      Terraform — see §2)
    → GitHub Actions polls DT, exports findings (FPF format)
    → imports into DefectDojo

Path 2 — SARIF (Checkov: any repo · Trivy: image-referencing repos)
GitHub Actions → Checkov / Trivy → SARIF output, dual-written:
    → github/codeql-action/upload-sarif → the repo's own GitHub Security
      tab (native, free PR annotations, if you use GitHub Advanced
      Security or code scanning)
    → DefectDojo import API (scan_type=SARIF) → same DefectDojo instance

Both paths converge on DefectDojo — one Product per repo, every finding
type. GitHub's Security tab keeps a native copy for PR-native
annotations, but is a convenience view, not the system of record: if the
two ever disagree, DefectDojo is authoritative.
```

### Component inventory

Everything below is defined in this repo's Terraform and lives in one resource group (`rg-<name_prefix>`), one Container Apps Environment (`cae-<name_prefix>`), backed by one Log Analytics workspace (`log-<name_prefix>`, 30-day retention). `<name_prefix>` is whatever you set for the `name_prefix` variable, letting multiple deployments coexist in one subscription/tenant:

| Component | Azure resource | Purpose |
|---|---|---|
| `ca-<name_prefix>-dt-api` | Container App, 1.0 vCPU / 2 GiB | Dependency-Track's API — what CI actually talks to |
| `ca-<name_prefix>-dt-fe` | Container App, 0.5 vCPU / 1 GiB | Dependency-Track's UI — stateless, no DB/Key Vault access |
| `ca-<name_prefix>-dd-web` | Container App, two containers (uwsgi 1.0 vCPU/2 GiB + nginx 0.25 vCPU/0.5 GiB) | DefectDojo's UI/API |
| `ca-<name_prefix>-dd-worker` | Container App, 0.5 vCPU / 1 GiB | DefectDojo's background job processor (import processing, notifications) |
| `ca-<name_prefix>-dd-beat` | Container App, 0.25 vCPU / 0.5 GiB | DefectDojo's scheduled-task trigger |
| One PostgreSQL Flexible Server (`B_Standard_B1ms`, 32 GB, v16) | Two databases: `dtrack`, `defectdojo` | Persistent state for both apps — one server to keep MVP cost down |
| One Azure Managed Redis instance (`Balanced_B0`) | — | DefectDojo's Celery broker only; Dependency-Track doesn't need it |
| One Key Vault (`kv-<name_prefix>-*`, RBAC-authorized) | — | Every generated credential: Postgres admin password, DefectDojo's secret key/AES key/admin password, Redis's access key |
| Two user-assigned managed identities (`id-<name_prefix>-dtrack`, `id-<name_prefix>-defectdojo`) | — | Each granted only `Key Vault Secrets User` on the vault — least-privilege, scoped per app |

### Why user-assigned identities, specifically

Each app's Container App resource references its Key Vault secrets via `identity = azurerm_user_assigned_identity.<app>.id`. This is a deliberate ordering choice: a user-assigned identity can be created and granted `Key Vault Secrets User` *before* the Container App that needs it exists, which avoids a circular dependency you'd otherwise hit with a system-assigned identity (the app needs Key Vault access to start, but doesn't get an identity to grant access to until it's already created).

### Deployment identity vs. application identities — two different trust boundaries

There are two separate identities in play, with different scopes:
- **`sp-security-platform-github-actions`** (or whatever you name it) — the OIDC-federated service principal GitHub Actions uses to run `terraform apply`. Scoped to `Contributor` on `rg-<name_prefix>` only, plus `Storage Blob Data Contributor` on the Terraform state storage account. This identity provisions infrastructure.
- **`id-<name_prefix>-dtrack` / `id-<name_prefix>-defectdojo`** — the two application identities described above. Scoped to `Key Vault Secrets User` only. These identities run the applications, and cannot provision or modify infrastructure.

Neither identity is broader than it needs to be, and compromising one doesn't hand over the other's capability.

---

## 4. Why Azure Container Apps

| Option | Verdict | Why |
|---|---|---|
| **Azure Container Apps** | **Chosen** | Managed, no cluster to patch, scales down when idle, matches "two lightly-loaded tools" — not "growing platform workload" |
| AKS | Deferred | Only justified once you're already running other workloads on a cluster, or this platform's load genuinely grows |
| Single VM / docker-compose | Rejected | Closest to each project's official quick-start, but you'd own patching, backups, and it's a single point of failure |

There's a spectrum of how much infrastructure you manage yourself:

- **A VM running docker-compose** — closest to how Dependency-Track and DefectDojo document their own quick-start, but you'd own patching the OS, patching Docker, and restarting things when they crash, and it's a single machine — if it goes down, both tools go down with it.
- **AKS (Kubernetes)** — the other extreme: powerful, but you'd be standing up and maintaining a cluster (node pools, upgrades, an ingress controller, certificate management) to run five small containers. Disproportionate infrastructure for two lightly-loaded tools.
- **Container Apps** — the middle ground: Azure manages the underlying compute and platform patching, and gives you HTTPS ingress and autoscaling without describing any of that yourself. It also scales down when idle, which matters here because this workload genuinely is idle most of the time — bursts of CI traffic, otherwise quiet.

Pick the option that matches the actual size of the problem — if this platform ever grows into real production load, AKS becomes the right call. That's a substantially easier position to defend than building the most defensible version possible on day one: it's cheaper, honest about the risk being carried, and doesn't block getting the actual value (CVE visibility) sooner.

---

## 5. Deployment rationale

### Why one Postgres server with two databases, not two servers

Two separate servers would isolate Dependency-Track's data from DefectDojo's more cleanly, but it's also double the fixed cost for what is, for most deployments, a small workload. One server with two databases (`dtrack`, `defectdojo`) is cheaper to start, and splitting them later is a contained migration if load or isolation requirements ever justify it — not a redesign.

### Why Redis exists for only one of the two apps

Dependency-Track doesn't need a cache or queue. Redis is here purely because DefectDojo uses Celery (a background task system) for things like processing an import or sending notifications, and Celery needs a message broker to talk to. Smallest tier, for the same reason as Postgres: this isn't a workload under real load.

### Resource footprint

The entire platform's baseline provisioned compute, at `min_replicas = 1` everywhere (no autoscale headroom included), is roughly:

```
vCPU:    2.0 (dtrack-api) + 0.5 (dtrack-frontend) + 1.25 (defectdojo-web)
       + 0.5 (celeryworker) + 0.25 (celerybeat)                = 4.5 vCPU
Memory:  4 + 1 + 2.5 + 1 + 0.5 GiB                              = 9 GiB
```

...plus one Burstable-tier Postgres server and the smallest Azure Managed Redis tier — deliberately the smallest managed SKUs available for each, appropriate for "two internal tools serving CI pipelines and a small triage team," not a production-facing service under load. Get a real pricing estimate for these exact SKUs in your target region before this goes in front of anyone approving budget.

### The secrets model: Key Vault + managed identity, no secrets anywhere else

This is usually the first thing a security-conscious reader asks about, so it's worth walking through slowly.

Every password — the Postgres admin password, DefectDojo's internal crypto keys, its admin login — is generated by Terraform and written straight into Key Vault. Nothing is typed by a person, nothing sits in a config file, nothing is in git.

Getting those secrets into the running containers without ever exposing them uses managed identity: each app has its own Azure identity, granted permission to read only the specific secrets it needs — nothing else. When a container starts, Azure fetches the secret directly from Key Vault using that identity and injects it as an environment variable; it's never visible in the Container App's config, in logs, or to a person without Key Vault access themselves.

There's a second identity worth calling out separately: the one GitHub Actions uses to deploy this infrastructure. It's a completely different identity with completely different permissions — it can create or modify infrastructure in the resource group, but it has no access to read any application secret. So even considering "what if the CI credentials leak," the answer is "an attacker could redeploy infrastructure, but couldn't read the running apps' passwords" — two separate blast radii, by design, not by accident. (Full detail in [§3](#3-architecture-in-detail), "Deployment identity vs. application identities.")

> If you grep this entire repo for a password, you'll find none — because there aren't any. Everything is generated at deploy time and handed only to the identity that needs it.

### Why public HTTPS + an IP allowlist, and not a private network from day one

This is the least mature part of the design, and it's worth calling out as an acknowledged tradeoff rather than glossing over it. The "correct" version puts everything on a private network with no public exposure at all. This platform doesn't start there because it adds real setup complexity (a VNet, private endpoints, DNS) for something that, on day one, holds no production-sensitive data. The sequencing is deliberate: prove the pipeline works, then harden the network before it holds anything that actually matters.

Every decision above follows the same rule: match the infrastructure to the actual size and maturity of the problem today, and write down explicitly what would change that decision later (real load → bigger Postgres/Redis tier or AKS; production-sensitive data → private networking; more usage → high availability — all tracked in [§7](#7-security-posture-and-known-gaps)).

---

## 6. Rollout approach

A phased rollout works better than onboarding every repo at once:

```
Phase A  Stand up the platform (this repo)
             ↓
Phase B  Wire one real repo's CI — proves the pipeline end-to-end
             ↓
Phase C  Extract the pipeline into this repo's reusable workflows,
         if it isn't already wired that way
             ↓
Onboard  Other Terraform repos — one-line addition each
         npm/CDK repos — same, one-line addition
         Bicep repos — see scope table below
```

It's cheap to bolt this on early and expensive to retrofit across a large estate later — onboarding one more repo later is a one-line workflow call, but retrofitting this decision across an estate that's grown for another year is a much bigger lift. The pipeline is observability-first, so there's no delivery-speed cost to adopting it early.

### Scope by repo type

| Repo type | Workflow | ROI |
|---|---|---|
| Terraform | `sbom-scan.yml` with `sbom_type: terraform` (reads `.terraform.lock.hcl`) | High — provider CVEs are real and often invisible |
| npm/CDK | `sbom-scan.yml` with `sbom_type: npm` (reads `package-lock.json`) | High — real npm dependency tree, same risk class as any Node.js app |
| Bicep | *(not onboarded to `sbom-scan.yml`)* | Low for SBOM specifically — no package manager for it to describe |

### How Bicep repos actually get covered

Bicep carries two distinct risks, and each gets matched to the right tool rather than forced through SBOM tooling that doesn't fit:

1. **Misconfiguration** — unchanged, Checkov (and PSRule, if used) continue exactly as before, findings now visible in the repo's GitHub Security tab via SARIF if you use it
2. **Container images referenced from the template** (Container Apps, AKS, App Service, Container Instances) — this *does* have real CVE data, and gets covered by [`image-scan.yml`](../.github/workflows/image-scan.yml): Trivy scans an explicit list of image references and dual-writes SARIF to both the GitHub Security tab and DefectDojo
3. **Registry-published Bicep modules** (third-party or externally-maintained) — genuine supply-chain exposure, but there's no CVE database for a Bicep module the way there is for an npm package. No scanner in this platform covers this; the control is provenance (pin to digest, restrict trusted registries, review module diffs in PR) — see `docs/how-to-use.md` §5a

If a Bicep repo has neither external modules nor container images, Checkov alone is genuinely sufficient — there's nothing to bolt on.

### Measuring whether it's working

Once you're past initial rollout, a few things worth tracking:

- **Coverage** — onboarded repos ÷ eligible repos
- **Time-to-visibility** — for a newly disclosed CVE affecting something already in an SBOM, time from disclosure to appearing as a Dependency-Track finding should be near-zero — that's the point of continuous re-scoring, versus a scan-time-only tool where it'd be "however long until the next scan"
- **Time-to-triage** — from a finding first appearing in DefectDojo to its status changing from the default — a proxy for whether anyone is actually looking
- **Backlog health** — count of Critical/High findings open longer than 30/60/90 days
- **GitHub/DefectDojo drift** — if you also use GitHub Advanced Security, spot-check periodically whether a finding dismissed in one system is still showing open in the other; if drift turns out common enough to cause real confusion, that's the signal to build reconciliation tooling rather than leave it accepted

---

## 7. Security posture and known gaps

**What's already handled:**
- No secrets in git — every credential is Terraform-generated and lives in Key Vault
- OIDC-based Azure auth from GitHub Actions — no long-lived cloud credentials stored in GitHub
- Managed identities, not shared service credentials, for each app's Key Vault access, scoped to `Key Vault Secrets User` only (see [§3](#3-architecture-in-detail))
- Terraform state protected via Azure AD auth on the storage account — no public access, no local plaintext state
- The deployment identity and the application identities are separate trust boundaries with independently minimal scopes (see [§3](#3-architecture-in-detail), [§5](#5-deployment-rationale))

**What's explicitly not solved yet (by design, for MVP):**

| Gap | Current mitigation | Follow-up |
|---|---|---|
| Ingress is public HTTPS, not a private VNet | IP allowlist (see README's "Known gaps" for the tradeoff with GitHub-hosted CI runners) | Move to VNet + private endpoints once real production vuln data lives here |
| No HA | Single Postgres/Redis instance, `min_replicas=1` everywhere | Revisit once real usage is known |
| No tested backup/restore | Postgres's built-in 7-day retention | Run a restore drill before this holds anything business-critical |
| Bicep repos have no dependency-level SBOM coverage | Checkov/PSRule cover misconfig; `image-scan.yml` covers referenced container images | No mitigation for registry-module provenance risk today — accepted, see §6 |
| `image-scan.yml`'s `image_refs` is manually maintained | Documented in `how-to-use.md` §5b | Could drift from what a template actually references; revisit auto-discovery once real template patterns are known |

---

## 8. Related documents

- [ADR-0001](adr/0001-sbom-and-vulnerability-management-platform.md) — the formal decision record
- [`README.md`](../README.md) — deployment bootstrap steps
- [`docs/how-to-use.md`](how-to-use.md) — day-to-day operation and the full onboarding walkthrough for every repo type
