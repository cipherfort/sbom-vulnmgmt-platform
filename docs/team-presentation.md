# SBOM & Vulnerability Management — Team Presentation
### CipherFort Cloud Platform · Security Engineering

---

## Agenda

1. [Executive summary](#1-executive-summary)
2. [What problem are we solving?](#2-what-problem-are-we-solving)
3. [Why now — industry and compliance context](#3-why-now--industry-and-compliance-context)
4. [Glossary](#4-glossary)
5. [Tool landscape — what we considered and why](#5-tool-landscape--what-we-considered-and-why)
6. [The recommendation](#6-the-recommendation)
7. [Architecture, in detail](#7-architecture-in-detail)
8. [Resource footprint and cost posture](#8-resource-footprint-and-cost-posture)
9. [Why Azure Container Apps](#9-why-azure-container-apps)
10. [Deployment rationale, decision by decision](#10-deployment-rationale-decision-by-decision)
11. [Anticipated questions from the team](#11-anticipated-questions-from-the-team)
12. [Repo rollout plan and scope](#12-repo-rollout-plan-and-scope)
13. [CI/CD walkthrough](#13-cicd-walkthrough)
14. [Demo script](#14-demo-script)
15. [Security posture and known gaps](#15-security-posture-and-known-gaps)
16. [Success metrics — how we'll know this is working](#16-success-metrics--how-well-know-this-is-working)
17. [Timeline and asks from the team](#17-timeline-and-asks-from-the-team)
18. [Appendix — related documents](#18-appendix--related-documents)

---

## 1. Executive summary

We have no visibility into vulnerable *dependencies* across our IaC estate — only into misconfiguration (Checkov). We're proposing to close that gap by standing up **Dependency-Track** (continuous SBOM/dependency-vulnerability monitoring) feeding **DefectDojo** (unified vulnerability management), self-hosted on Azure Container Apps, rolled out through a reusable GitHub Actions workflow so onboarding any future repo is a one-line change.

This is deliberately **observability-first**: nothing blocks a PR on day one. The ask of this presentation is sign-off to deploy the platform (Azure subscription, IP allowlist, approval reviewers — see [§17](#17-timeline-and-asks-from-the-team)) and agreement on the scope decisions already made (Terraform and npm repos onboarded now; Bicep repos get a narrower, purpose-fit treatment — [§12](#12-repo-rollout-plan-and-scope)).

**If your first reaction is "don't we already have GitHub Advanced Security Enterprise for this" — yes, and we checked.** GHAS has zero vulnerability-detection coverage for Terraform providers, confirmed against GitHub's own current documentation, not assumed (§5). That gap is this platform's entire reason to exist. Where GHAS *does* already cover something — npm dependencies, and anything expressible as SARIF (Checkov, Trivy) — we use it rather than duplicate it, and route those findings into DefectDojo too so there's still one place to look across every repo (§5, §7).

The formal decision record for this choice is [ADR-0001](adr/0001-sbom-and-vulnerability-management-platform.md), which includes the verification of what GitHub Advanced Security (GHAS) Enterprise — already licensed org-wide — actually covers, and how findings are routed so DefectDojo remains a genuine single pane across every repo; see [§5](#5-tool-landscape--what-we-considered-and-why).

---

## 2. What problem are we solving?

### Where we are today

```
47+ policy definitions, multiple Terraform/Bicep IaC repos, an AWS Landing
Zone Accelerator repo — and growing.

Checkov scans every one of them for misconfiguration
    (a Deny-effect policy assigned wrong, a public storage account, ...)

Nothing scans what those repos actually *depend on*:
    - Terraform providers (hashicorp/azurerm, hashicorp/azuread, ...)
    - npm packages in the CDK-based Landing Zone Accelerator repo
    - Any container images referenced from IaC

A CVE lands in a Terraform provider or an npm dependency next month.
We have no mechanism that tells us. We find out when someone reads a
security mailing list, or we don't find out at all.
```

**Checkov ≠ SBOM/SCA.** Checkov answers "is this resource configured safely?" It has no concept of "is the *tool that configures it* itself carrying a known vulnerability?" These are two different risk categories and need two different controls. A Terraform provider with a supply-chain-injected backdoor, or a dependency with a remote-code-execution CVE, would sail through Checkov clean — Checkov never looks at provider/package versions at all.

### The gap, concretely

| Risk category | Example | Current coverage |
|---|---|---|
| IaC misconfiguration | Storage account allows public blob access | ✅ Checkov (`ci.yml` `security-scan` job) |
| Vulnerable dependency — Terraform | A Terraform provider version with a published CVE | ❌ Nothing, GHAS included — verified, not assumed (§5) |
| Vulnerable dependency — npm | An npm package version with a published CVE, in the CDK-based repo | ✅ Already covered natively by GHAS Dependabot (§5) — we keep it on our own pipeline too, deliberately, for consistency |
| Vulnerable container image | An image referenced from a Bicep/Terraform-deployed workload carrying known CVEs | ❌ Nothing (GHAS has no image-scanning capability at all) |
| Vuln lifecycle / triage / SLA | Who owns fixing it, by when, has it been fixed | ❌ Nothing platform-wide — GHAS's own Security overview only covers GHAS-sourced findings, not Terraform's |
| Audit trail for "what did we know, when" | Compliance / incident response evidence | ❌ Nothing |

### Why this matters now, not later

- Repo count keeps growing — the cost of *not* having this compounds every repo we add
- It's cheap to bolt on now, at pilot scale, and expensive to retrofit across 20+ repos later — onboarding one more repo later is a one-line workflow call; retrofitting this decision across an estate that's grown for another year is a much bigger lift
- The pipeline is observability-first, so there's no delivery-speed cost to adopting it early — it produces evidence and visibility without gating anything

---

## 3. Why now — industry and compliance context

This isn't a purely internal preference — SBOM production and dependency vulnerability tracking have become a baseline industry expectation over the last few years:

- **NTIA "minimum elements for an SBOM"** — the US National Telecommunications and Information Administration's baseline definition of what a usable SBOM contains; it's become the de facto reference point most tooling (including CycloneDX) targets
- **CISA supply-chain guidance** — increasingly the reference security teams point to when asking "can you produce an SBOM for X"
- **Executive Order 14028** (US federal software supply chain requirements) — relevant context even outside direct federal contracting, since it shaped what "SBOM" means as a deliverable across the industry
- **Vendor/customer security questionnaires** — SIG, CAIQ, and similar assessments increasingly include explicit questions about dependency vulnerability management and SBOM availability; ISO 27001 Annex A and SOC 2 common-criteria mappings both touch on vulnerability management as a control area

None of this means we're currently under a specific external mandate to do this — if we are, that strengthens the case further and is worth confirming separately. Even without one, the direction of travel across the industry makes this a "when," not an "if," and doing it now, before someone asks for it under time pressure (an audit, a customer questionnaire, an incident), is the cheaper path.

---

## 4. Glossary

| Term | Meaning here |
|---|---|
| **SBOM** | Software Bill of Materials — a machine-readable inventory of everything a piece of software depends on |
| **CycloneDX** | The SBOM format we use (as opposed to the other common one, SPDX). Chosen because Dependency-Track is built around it natively, and `cdxgen` produces it directly from Terraform/npm/many other ecosystems |
| **SCA** | Software Composition Analysis — matching an SBOM's components against vulnerability databases, continuously, not just once |
| **CVE / CVSS** | CVE = a published vulnerability's unique identifier. CVSS = its severity score (0–10) |
| **NVD / GHSA / OSV** | The vulnerability databases Dependency-Track cross-references: the National Vulnerability Database, GitHub Security Advisories, and the Open Source Vulnerabilities database |
| **FPF** | "Finding Packaging Format" — Dependency-Track's own JSON export format for findings, which DefectDojo knows how to import natively |
| **Product / Engagement** | DefectDojo's organizing concepts — one Product per repo, one Engagement per import (named after the commit SHA that triggered it) |
| **Finding** | A single tracked issue in DefectDojo — one per vulnerable component/CVE pairing (or, for image scans, per image/CVE pairing) |
| **SLA** | In DefectDojo, a due-date policy attached to a finding based on severity, if configured |
| **OIDC** | OpenID Connect — how GitHub Actions authenticates to Azure without storing a long-lived credential, same pattern the policy repo already uses |
| **Managed Identity** | An Azure AD identity attached directly to a resource (here, a Container App) instead of a shared credential — used so each app can read only the Key Vault secrets it needs |

---

## 5. Tool landscape — what we considered and why

| Option | SBOM/SCA depth | Vuln mgmt (ticketing/SLA/dedup) | Multi-scanner aggregation | Cost model | Verdict |
|---|---|---|---|---|---|
| **Dependency-Track + DefectDojo** | Excellent (DT is purpose-built, OWASP flagship) | Excellent (DD's core purpose) | Excellent — DD ingests SAST/DAST/IaC/SCA from ~150 scanner formats | Self-hosted, no license fee | **Recommended** |
| DefectDojo alone (skip DT) | Weak — DD can import an SBOM but doesn't do DT's continuous re-scoring against newly published CVEs | Excellent | Excellent | Self-hosted, no license fee | Rejected — loses continuous monitoring, findings only refresh when we re-run a scan |
| Dependency-Track alone (skip DD) | Excellent | None — no ticketing, no cross-tool dedup, no SLA | None — SCA only | Self-hosted, no license fee | Rejected — leaves the actual "management" half of the ask unsolved |
| Commercial SaaS (Snyk, Mend, JFrog Xray) | Good–excellent | Varies, generally weaker cross-scanner aggregation than DefectDojo | Varies | Per-seat/per-repo licensing, scales with repo count | Rejected/deferred — recurring cost that scales exactly as our repo count grows; data leaves our tenant |
| GitHub Advanced Security / Dependabot (already licensed — Enterprise) | Verified against current GitHub docs: **no** Dependency Graph support for Terraform → no security alerts, no native SBOM coverage for it. **Full** support for npm (Dependency Graph, alerts, native SPDX SBOM export) | Native for GHAS-sourced findings (Dependabot/CodeQL/secret scanning) only; also ingests arbitrary SARIF (used for Checkov/Trivy — see below) | Org-wide Security overview aggregates GHAS-native + SARIF-uploaded findings | Already paid for | **Partially adopted, not rejected** — see ADR-0001: covers Checkov/Trivy (via SARIF) and already covers npm, but still has zero Terraform coverage, which is the platform's core reason to exist |
| Trivy/Grype at scan time only, no persistent platform | Fair | None | None | Free, but point-in-time only | Rejected — no continuous monitoring, no central record, findings live only in a CI log |
| Status quo (Checkov only) | None | None | None | — | Rejected — this is the gap we're closing |

### Why not just pick one tool?

The natural question is "why run two applications instead of one." The honest answer: no single tool available to us does both jobs well.

- Dependency-Track's entire design center is "ingest an SBOM once, keep matching it against new CVEs forever." It has no concept of assigning a finding to a person, tracking it against an SLA, or recognizing that the same underlying issue showed up from two different scanners.
- DefectDojo's entire design center is the opposite: it's a triage/ticketing/reporting layer that's deliberately scanner-agnostic — it imports findings from ~150 different tool output formats. It does not itself re-derive "is this dependency vulnerable" on an ongoing basis; it just tracks whatever a scan told it.

Chaining them plays to each tool's actual strength, and DefectDojo's cross-scanner aggregation capability is what makes it the single pane across every scanner in this platform, not just Dependency-Track's (see below).

### Why GHAS Enterprise doesn't replace this — verified, not assumed

We already have GitHub Advanced Security (GHAS) Enterprise licensed, which raised the obvious question: do we need any of this? We checked against GitHub's current documentation rather than assuming, and the answer split by repo type (ADR-0001 has the full verification):

- **Terraform — no overlap at all.** GHAS's vulnerability alerting (Dependabot alerts) requires the ecosystem to be supported by GitHub's Dependency Graph, and Terraform is not a supported Dependency Graph ecosystem — confirmed directly from GitHub's own docs, not inferred. No alerts, no native SBOM coverage. This is the platform's entire reason to exist, and GHAS doesn't touch it.
- **npm (the AWS Landing Zone Accelerator repo) — full overlap.** GHAS's Dependabot support for npm is mature: Dependency Graph, security alerts, and native SPDX SBOM export all work today. We're keeping that repo on our own pipeline too anyway, deliberately, for one consistent place to check across every onboarded repo rather than splitting by repo type — a known, accepted duplication, not an oversight.
- **Checkov and Trivy — dual-written to both.** Both output SARIF, which GHAS ingests natively into the same Security tab as Dependabot/CodeQL, giving PR-native inline annotations GHAS is good at. The same SARIF file is *also* imported into DefectDojo (it has a generic SARIF importer — verified, not assumed), so DefectDojo holds every finding type for every repo, and GHAS's tab is a convenience view rather than a second source of truth.

### On cost

We're not presenting hard dollar figures here — get an actual Azure Pricing Calculator estimate for the specific SKUs before quoting a number to anyone deciding budget. What we can say directionally: every commercial alternative in the table above prices per seat or per repo, meaning the bill grows every time we onboard another repo. The self-hosted option's marginal cost of onboarding repo #21 is effectively zero — it's the same Dependency-Track/DefectDojo instance ingesting one more SBOM. The cost we do carry instead is engineering time for patching and uptime (see [§15](#15-security-posture-and-known-gaps)) — a real cost, just a different shape than a recurring license.

---

## 6. The recommendation

Adopt **Dependency-Track** (SBOM ingestion, continuous CVE monitoring) feeding **DefectDojo** (unified vulnerability management, one product per repo) as the team standard, self-hosted on **Azure Container Apps**.

Rolled out via **reusable GitHub Actions workflows** that any onboarded repo calls with a handful of lines — no copy-pasted CI logic to maintain per repo:
- [`sbom-scan.yml`](../.github/workflows/sbom-scan.yml) — Terraform and npm/CDK repos
- [`image-scan.yml`](../.github/workflows/image-scan.yml) — container images referenced from any repo's IaC (this is how Bicep repos participate — see [§12](#12-repo-rollout-plan-and-scope))

---

## 7. Architecture, in detail

### Data flow

*(A drawn version of this — the two paths converging on DefectDojo, with the dual-write fork called out — is in the [Findings Routing diagram](https://claude.ai/code/artifact/5af41c3c-35ad-4e9f-a414-666542f6820c); the ASCII version below is the git-committed reference.)*

```
Path 1 — SBOM (Terraform + npm repos)
GitHub Actions → cdxgen → bom.json (CycloneDX)
    → Dependency-Track (continuously re-scores against NVD/GHSA/OSV;
      this is the coverage GHAS Enterprise cannot provide for Terraform —
      see §5, "Why GHAS Enterprise doesn't replace this")
    → GitHub Actions polls DT, exports findings (FPF format)
    → imports into DefectDojo

Path 2 — SARIF (Checkov: any repo · Trivy: image-referencing repos)
GitHub Actions → Checkov / Trivy → SARIF output, dual-written (ADR-0001):
    → github/codeql-action/upload-sarif → the repo's own GitHub Security
      tab (GHAS-native — free PR annotations)
    → DefectDojo import API (scan_type=SARIF) → same DefectDojo instance

Both paths converge on DefectDojo — one Product per repo, every finding
type. GHAS's Security tab keeps a native copy for PR-native annotations,
but is a convenience view, not the system of record: if the two ever
disagree, DefectDojo is authoritative.
```

### Component inventory

Everything below is defined in this repo's Terraform and lives in one resource group (`rg-security-platform`), one Container Apps Environment (`cae-security-platform`), backed by one Log Analytics workspace (`log-security-platform`, 30-day retention):

| Component | Azure resource | Purpose |
|---|---|---|
| `ca-dtrack-api` | Container App, 1.0 vCPU / 2 GiB | Dependency-Track's API — what CI actually talks to |
| `ca-dtrack-frontend` | Container App, 0.5 vCPU / 1 GiB | Dependency-Track's UI — stateless, no DB/Key Vault access |
| `ca-defectdojo-web` | Container App, two containers (uwsgi 1.0 vCPU/2 GiB + nginx 0.25 vCPU/0.5 GiB) sharing an ephemeral volume | DefectDojo's UI/API |
| `ca-defectdojo-celeryworker` | Container App, 0.5 vCPU / 1 GiB | DefectDojo's background job processor (import processing, notifications) |
| `ca-defectdojo-celerybeat` | Container App, 0.25 vCPU / 0.5 GiB | DefectDojo's scheduled-task trigger |
| One PostgreSQL Flexible Server (`B_Standard_B1ms`, 32 GB, v16) | Two databases: `dtrack`, `defectdojo` | Persistent state for both apps — one server to keep MVP cost down |
| One Azure Cache for Redis (`Basic`, `C0`) | — | DefectDojo's Celery broker only; Dependency-Track doesn't need it |
| One Key Vault (`kv-secplat-*`, RBAC-authorized) | — | Every generated credential: Postgres admin password, DefectDojo's secret key/AES key/admin password, Redis's access key |
| Two user-assigned managed identities (`id-dtrack`, `id-defectdojo`) | — | Each granted only `Key Vault Secrets User` on the vault — least-privilege, scoped per app |

### Why user-assigned identities, specifically

Each app's Container App resource references its Key Vault secrets via `identity = azurerm_user_assigned_identity.<app>.id`. This is a deliberate ordering choice: a user-assigned identity can be created and granted `Key Vault Secrets User` *before* the Container App that needs it exists, which avoids a circular dependency you'd otherwise hit with a system-assigned identity (the app needs Key Vault access to start, but doesn't get an identity to grant access to until it's already created).

### Deployment identity vs. application identities — two different trust boundaries

It's worth being explicit that there are two separate identities in play, with different scopes:
- **`sp-security-platform-github-actions`** — the OIDC-federated service principal GitHub Actions uses to run `terraform apply`. Scoped to `Contributor` on `rg-security-platform` only, plus `Storage Blob Data Contributor` on the Terraform state storage account. This identity provisions infrastructure.
- **`id-dtrack` / `id-defectdojo`** — the two application identities described above. Scoped to `Key Vault Secrets User` only. These identities run the applications, and cannot provision or modify infrastructure.

Neither identity is broader than it needs to be, and compromising one doesn't hand over the other's capability.

---

## 8. Resource footprint and cost posture

The entire platform's baseline provisioned compute, at `min_replicas = 1` everywhere (no autoscale headroom included), is:

```
vCPU:    1.0 (dtrack-api) + 0.5 (dtrack-frontend) + 1.25 (defectdojo-web) 
       + 0.5 (celeryworker) + 0.25 (celerybeat)                = 3.5 vCPU
Memory:  2 + 1 + 2.5 + 1 + 0.5 GiB                              = 7 GiB
```

...plus one Burstable-tier Postgres server (1 vCore / 2 GiB class) and one Basic-tier Redis cache (250 MB) — deliberately the smallest managed SKUs Azure offers for each, appropriate for "two internal tools serving CI pipelines and a small triage team," not a production-facing service under load.

**On cost:** get a real Azure Pricing Calculator estimate for these exact SKUs in the target region before this goes in front of anyone approving budget — we haven't quoted one here (see [§5](#5-tool-landscape--what-we-considered-and-why) "On cost" for why we're not putting a number on it in this document). What we can say with confidence: Container Apps' consumption pricing model means idle time (nights, weekends) costs less than a fixed-size VM or AKS node pool would for the same workload, and none of the SKUs chosen here are the higher tiers — there's very little "premium feature" cost baked in.

**This spend is additive to GHAS, not instead of it.** The GHAS Enterprise license is a fixed cost regardless of whether this platform exists — nothing here reduces or replaces it, and nothing about deploying this platform is contingent on GHAS's pricing. The only new spend this introduces is the Azure infrastructure above, justified purely by the Terraform coverage gap GHAS doesn't close.

---

## 9. Why Azure Container Apps

| Option | Verdict | Why |
|---|---|---|
| **Azure Container Apps** | **Chosen** | Managed, no cluster to patch, scales down when idle, matches "two lightly-loaded internal tools" — not "growing platform workload" |
| AKS | Deferred | Only justified once we're already running other workloads on a cluster, or this platform's load genuinely grows |
| Single VM / docker-compose | Rejected | Closest to each project's official quick-start, but we'd own patching, backups, and it's a single point of failure |

---

## 10. Deployment rationale, decision by decision

§7–9 covered *what* was built and the top-level hosting choice. This section is the fuller "why this, not the obvious alternative" for each piece — useful for walking a technical audience through the reasoning live, not just the conclusion.

### Why Container Apps, not a VM or AKS

There's a spectrum of how much infrastructure we manage ourselves:

- **A VM running docker-compose** — closest to how Dependency-Track and DefectDojo document their own quick-start, but we'd own patching the OS, patching Docker, and restarting things when they crash, and it's a single machine — if it goes down, both tools go down with it.
- **AKS (Kubernetes)** — the other extreme: powerful, but we'd be standing up and maintaining a cluster (node pools, upgrades, an ingress controller, certificate management) to run five small containers. Disproportionate infrastructure for two lightly-loaded internal tools.
- **Container Apps** — the middle ground: Azure manages the underlying compute and platform patching, and gives us HTTPS ingress and autoscaling without us describing any of that ourselves. It also scales down when idle, which matters here because this workload genuinely is idle most of the time — bursts of CI traffic, otherwise quiet.

> *The line to use with the team: "We picked the option that matches the actual size of the problem — if this platform ever grows into real production load, AKS becomes the right call, and we're saying so explicitly rather than guessing wrong now."*

### Why one Postgres server with two databases, not two servers

Two separate servers would isolate Dependency-Track's data from DefectDojo's more cleanly, but it's also double the fixed cost for what is, today, a small workload. One server with two databases (`dtrack`, `defectdojo`) is cheaper to start, and splitting them later is a contained migration if load or isolation requirements ever justify it — not a redesign.

### Why Redis exists for only one of the two apps

Dependency-Track doesn't need a cache or queue. Redis is here purely because DefectDojo uses Celery (a background task system) for things like processing an import or sending notifications, and Celery needs a message broker to talk to. Smallest tier, for the same reason as Postgres: this isn't a workload under real load yet.

### The secrets model: Key Vault + managed identity, no secrets anywhere else

This is the strongest part of the story and worth walking through slowly, since it's usually the first thing a security-conscious audience worries about.

Every password — the Postgres admin password, DefectDojo's internal crypto keys, its admin login — is generated by Terraform and written straight into Key Vault. Nothing is typed by a person, nothing sits in a config file, nothing is in git.

Getting those secrets into the running containers without ever exposing them uses managed identity: each app has its own Azure identity, granted permission to read only the specific secrets it needs — nothing else. When a container starts, Azure fetches the secret directly from Key Vault using that identity and injects it as an environment variable; it's never visible in the Container App's config, in logs, or to a person without Key Vault access themselves.

There's a second identity worth calling out separately: the one GitHub Actions uses to deploy this infrastructure (`sp-security-platform-github-actions`). It's a completely different identity with completely different permissions — it can create or modify infrastructure in the resource group, but it has no access to read any application secret. So even considering "what if the CI credentials leak," the answer is "an attacker could redeploy infrastructure, but couldn't read the running apps' passwords" — two separate blast radii, by design, not by accident. (Full detail in [§7](#7-architecture-in-detail), "Deployment identity vs. application identities.")

> *The line to use with the team: "If you grep this entire repo for a password, you'll find none — because there aren't any. Everything is generated at deploy time and handed only to the identity that needs it."*

### Why public HTTPS + an IP allowlist, and not a private network from day one

This is the least mature part of the design, and it's worth presenting as an acknowledged tradeoff rather than glossing over it. The "correct" version puts everything on a private network with no public exposure at all. We didn't build that first because it adds real setup complexity (a VNet, private endpoints, DNS) for a platform that, on day one, holds no production-sensitive data. The sequencing is deliberate: prove the pipeline works, then harden the network before it holds anything that actually matters — not "we didn't think about it."

### The thread connecting all of it

Every decision above follows the same rule: match the infrastructure to the actual size and maturity of the problem today, and write down explicitly what would change that decision later (real load → bigger Postgres/Redis tier or AKS; production-sensitive data → private networking; more usage → high availability — all tracked in [§15](#15-security-posture-and-known-gaps)). That's a substantially easier position to defend live than "we built the most defensible version possible on day one" — it's cheaper, it's honest about the risk being carried, and it doesn't block getting the actual value (CVE visibility) sooner.

---

## 11. Anticipated questions from the team

A quick-reference for the pushback this is most likely to get in the room:

| They ask | You say |
|---|---|
| "We already have GHAS Enterprise — why isn't that enough?" | Checked against GitHub's own current docs, not assumed: GHAS has zero vulnerability coverage for Terraform providers — no Dependency Graph support, no alerts, no SBOM export. That's this platform's entire reason to exist. Where GHAS *does* cover something (npm, anything SARIF-shaped) we use it and dual-write into DefectDojo rather than duplicate the work — see §5 and ADR-0001 |
| "Why not just buy Snyk/Mend and skip all this hosting?" | Per-seat/per-repo licensing that scales with our repo count forever; self-hosting costs us engineering time instead, and the marginal cost of onboarding repo #21 is close to zero |
| "Isn't running our own security tools risky?" | The tools themselves are OWASP Foundation open-source projects, widely deployed elsewhere; the risk we own is patching/uptime, which we're accepting knowingly, not by accident |
| "Why is this reachable from the internet at all?" | IP-allowlisted, not open to the world; explicitly flagged as the first thing to harden before this holds anything sensitive |
| "What if the CI credentials leak?" | That identity can't read any application secret — it can only manage infrastructure. Separate blast radius, by design |
| "Why isn't this highly available?" | Nothing here is business-critical yet — it's CI tooling and a small triage backlog. HA is a deliberate, written-down follow-up, not an oversight |
| "Why two applications instead of one?" | No single tool does continuous SBOM/SCA and ticketing/SLA management both well — see [§5](#5-tool-landscape--what-we-considered-and-why), "Why not just pick one tool?" |
| "What does this cost?" | Deliberately not quoted here without a real pricing estimate for the exact SKUs — see [§8](#8-resource-footprint-and-cost-posture) |

---

## 12. Repo rollout plan and scope

```
Phase A  Stand up the platform (this repo)
             ↓
Phase B  Wire the pilot repo's CI (azure-policy-as-code-terraform) —
         proves the pipeline end-to-end on one real repo first
             ↓
Phase C  Extract the pipeline into this repo's reusable workflows
             ↓
Onboard  AWS Landing Zone Accelerator repo (npm/CDK) — one-line addition
         Other Terraform repos — same, one-line addition
         Bicep repos — see scope table below
```

We're currently between Phase A and B: the pilot repo's CI already has the SBOM job wired in (gracefully no-op until the platform exists), and this repo's Terraform is scaffolded and validated but not yet deployed.

### Scope by repo type

| Repo type | Workflow | ROI |
|---|---|---|
| Terraform | `sbom-scan.yml` with `sbom_type: terraform` (reads `.terraform.lock.hcl`) | High — provider CVEs are real and currently invisible |
| AWS Landing Zone Accelerator (CDK/TypeScript) | `sbom-scan.yml` with `sbom_type: npm` (reads `package-lock.json`) | High — real npm dependency tree, same risk class as any Node.js app |
| Bicep | *(not onboarded to `sbom-scan.yml`)* | Low for SBOM specifically — no package manager for it to describe |

### How Bicep repos actually get covered

Bicep carries two distinct risks, and each gets matched to the right tool rather than forced through SBOM tooling that doesn't fit:

1. **Misconfiguration** — unchanged, Checkov (and PSRule, if used) continue exactly as today, findings now visible in the repo's GHAS Security tab via SARIF
2. **Container images referenced from the template** (Container Apps, AKS, App Service, Container Instances) — this *does* have real CVE data, and gets covered by [`image-scan.yml`](../.github/workflows/image-scan.yml): Trivy scans an explicit list of image references and dual-writes SARIF to both the GHAS Security tab and DefectDojo (see ADR-0001)
3. **Registry-published Bicep modules** (third-party or externally-maintained) — genuine supply-chain exposure, but there's no CVE database for a Bicep module the way there is for an npm package. No scanner in this platform covers this; the control is provenance (pin to digest, restrict trusted registries, review module diffs in PR) — see `docs/how-to-use.md` §5a if this becomes a live concern for a specific repo

If a Bicep repo has neither external modules nor container images, Checkov alone is genuinely sufficient — there's nothing to bolt on.

### Integrating repos beyond the pilot — what actually changes per repo

Every future repo's onboarding is the same shape regardless of what its existing CI/CD looks like: add the relevant secrets/variables, add one job calling `sbom-scan.yml` and/or `image-scan.yml`. What differs is how that job fits into a repo's *existing* workflow structure — a repo with separate PR/merge workflows (like the pilot), a repo with one combined workflow, or a repo with its own deployment matrix all need a slightly different wiring of the same job. The full pattern-by-pattern guide, including a concrete YAML example for each shape and guidance on pinning the workflow reference to a tag instead of `@main` once multiple repos depend on it, is in [`docs/how-to-use.md` §4, Step 5](how-to-use.md#4-onboarding-a-new-repo--step-by-step) — that's the one to have open when actually wiring up the next repo.

---

## 13. CI/CD walkthrough

### On a Pull Request

```
PR opened/updated on an onboarded repo
    │
    ├── security-scan job (Checkov) — every repo, every PR
    │     │
    │     ├── hard-fails the PR on a finding, unchanged from before this
    │     │   platform existed (soft_fail: false)
    │     ├── uploads SARIF to the repo's GitHub Security tab
    │     └── if DEFECTDOJO_URL is set: also imports the same SARIF into
    │           DefectDojo (scan_type=SARIF) — dual-write, ADR-0001
    │
    ├── sbom-scan job (cdxgen generates bom.json) — Terraform/npm repos
    │     │
    │     ├── always: upload bom.json as a build artifact
    │     └── if DEPENDENCY_TRACK_URL is set: upload to Dependency-Track,
    │           tagged as project version "pr-<number>"
    │
    └── (repos with image_refs configured) image-scan job — Trivy scans
          the configured image list, dual-writes SARIF the same way as
          Checkov above (runs the same way on every PR — no PR-vs-merge
          distinction needed, unlike the SBOM path below)
```

Nothing here blocks the PR except Checkov, which already blocked it before this platform existed. If the Dependency-Track/DefectDojo variables aren't set yet (e.g. before the platform is deployed), every dual-write/upload step skips silently — this is deliberate graceful degradation, not a failure mode.

### On merge to the default branch

```
Push to main
    │
    ├── security-scan job — same as the PR run, dual-write unaffected by
    │     the PR-vs-merge distinction (SARIF findings aren't versioned
    │     by branch the way Dependency-Track projects are)
    │
    ├── sbom-scan job — same as above, tagged as project version "main"
    │     │
    │     └── on successful upload → defectdojo-import job:
    │           1. poll Dependency-Track until the SBOM finishes processing
    │              (component count becomes non-zero; 15s interval, 10 min timeout)
    │           2. export findings in FPF format
    │           3. import into DefectDojo — engagement named "cd-<sha>",
    │              close_old_findings=true so resolved issues auto-close
    │
    └── (repos with image_refs configured) image-scan job — same as the
          PR run
```

Dependency-Track's findings only reach DefectDojo on merge, deliberately — so that half of DefectDojo's backlog reflects what's actually deployed, not every open PR branch. Checkov/Trivy's SARIF findings reach DefectDojo (and GHAS) on every PR *and* every merge — there's no equivalent branch-scoping concept for SARIF the way Dependency-Track has project versions, so it dual-writes every run.

---

## 14. Demo script

A suggested walkthrough for presenting this live once the platform is deployed:

**Demo 1 — SBOM generation on a PR**
1. Open a PR that bumps a Terraform provider version (or any small change) in an onboarded repo
2. Show the `sbom-scan` job running in the Actions tab
3. Download the `bom.json` artifact, show `jq '.components[] | select(.name=="azurerm")'` — the exact provider version this PR uses
4. Switch to the Dependency-Track UI, show the `pr-<number>` project that appeared, with the same component list

**Demo 2 — the finding lifecycle**
1. Merge that PR
2. Show the `cd.yml` run: `sbom-scan` job, then `defectdojo-import` picking up once it succeeds
3. Switch to DefectDojo, open the repo's Product, show the new Engagement and any findings (or, if there genuinely are none yet, explain that's the expected state for a clean estate — pick a component with a known older CVE ahead of time if you want a guaranteed finding to show)
4. Walk through triaging one finding: assign it, set a status, show the SLA due date

**Demo 3 — image scanning, dual-write (if presenting to a Bicep-heavy audience)**
1. Show a Bicep repo's `image-scan.yml` call with its `image_refs` list
2. Run it, show the SARIF artifact
3. Switch to that repo's GitHub Security tab, show the resulting Trivy findings alongside any Dependabot/CodeQL alerts already there
4. Then switch to DefectDojo, same repo's Product — show the same findings landed there too, same commit SHA in the engagement name. This is the point of the demo: one SARIF file, one CI step, and the finding is visible in both places without anyone doing double work

---

## 15. Security posture and known gaps

**What's already handled:**
- No secrets in git — every credential is Terraform-generated and lives in Key Vault
- OIDC-based Azure auth from GitHub Actions — no long-lived cloud credentials stored in GitHub, same pattern the policy repo already uses
- Managed identities, not shared service credentials, for each app's Key Vault access, scoped to `Key Vault Secrets User` only (see [§7](#7-architecture-in-detail))
- Terraform state itself is protected the same way the policy repo's state is — Azure AD auth on the storage account, no public access, no local plaintext state
- The deployment identity and the application identities are separate trust boundaries with independently minimal scopes (see [§7](#7-architecture-in-detail), [§10](#10-deployment-rationale-decision-by-decision))

**What's explicitly not solved yet (by design, for MVP):**

| Gap | Current mitigation | Follow-up |
|---|---|---|
| Ingress is public HTTPS, not a private VNet | IP allowlist (office/VPN + CI runner egress) | Move to VNet + private endpoints once real production vuln data lives here |
| DefectDojo image env-vars/paths unverified against a live container | Written from the documented public reference | Verify against the pinned image tag before first apply |
| No HA | Single Postgres/Redis instance, `min_replicas=1` everywhere | Revisit once real usage is known |
| No tested backup/restore | Postgres's built-in 7-day retention | Run a restore drill before this holds anything business-critical |
| Bicep repos have no dependency-level SBOM coverage | Checkov/PSRule cover misconfig; `image-scan.yml` covers referenced container images | No mitigation for registry-module provenance risk today — accepted, see §12 |
| `image-scan.yml`'s `image_refs` is manually maintained | Documented in `how-to-use.md` §5b | Could drift from what a template actually references; revisit auto-discovery once real template patterns are known |

---

## 16. Success metrics — how we'll know this is working

We don't have live usage yet, so treat these as the metrics to start tracking from day one of Phase B, not results to report today:

- **Coverage** — onboarded repos ÷ eligible repos (Terraform + npm repos; Bicep repos counted separately against the image-scan/provenance criteria in §12)
- **Time-to-visibility** — for a newly disclosed CVE affecting something already in an SBOM, time from disclosure to appearing as a Dependency-Track finding should be near-zero (this is the entire point of continuous re-scoring, vs. a scan-time-only tool where it'd be "however long until the next scan")
- **Time-to-triage** — from a finding first appearing in DefectDojo to its status changing from the default — a proxy for whether anyone is actually looking
- **Backlog health** — count of Critical/High findings open longer than 30/60/90 days
- **Clean-estate ratio** — % of onboarded repos with zero open, un-risk-accepted Critical findings
- **GHAS/DefectDojo drift** — spot-check periodically whether a finding dismissed in one system is still showing open in the other (ADR-0001 flagged this as a known gap — the two don't sync); if drift turns out to be common enough to cause real confusion, that's the signal to build reconciliation tooling rather than leave it as an accepted risk

---

## 17. Timeline and asks from the team

- [ ] Confirm which Azure subscription this platform deploys into
- [ ] Provide the IP ranges to allowlist (office/VPN egress, CI runner egress)
- [ ] Decide who reviews the `security-platform` GitHub Environment's deploy approvals
- [ ] Agree the point at which findings start *blocking* PRs vs. remaining observability-only
- [ ] Confirm DefectDojo product/engagement naming convention across repos (one product per repo is the default assumption)
- [ ] For each Bicep repo: confirm whether it references container images or external registry modules, to decide if it needs `image-scan.yml` onboarding or is Checkov-only
- [ ] Confirm native GHAS Dependabot alerts + SBOM export stay enabled on the npm/CDK repo alongside our own pipeline (ADR-0001) — no reason to turn off something already licensed
- [ ] Confirm code scanning (SARIF upload) and Dependabot are actually *enabled* per-repo on every repo being onboarded — an Enterprise license makes the features available org-wide, it doesn't turn them on for a given repo automatically

---

## 18. Appendix — related documents

- [ADR-0001](adr/0001-sbom-and-vulnerability-management-platform.md) — the formal decision record, including the GHAS Enterprise coverage verification (Terraform: nothing; npm: full; Checkov/Trivy: SARIF-ingestible) and the dual-write routing decision
- [Findings Routing diagram](https://claude.ai/code/artifact/5af41c3c-35ad-4e9f-a414-666542f6820c) — the dual-write flow, drawn
- [`README.md`](../README.md) — deployment bootstrap steps
- [`docs/how-to-use.md`](how-to-use.md) — day-to-day operation and the full onboarding walkthrough for every repo type, including how to integrate future repos' CI/CD (§4, Step 5)
