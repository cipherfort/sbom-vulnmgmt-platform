# ADR-0001: Collect GitHub's dependency-graph SBOMs into Dependency-Track

**Status:** Proposed, 11 Nov 2026. Replaces the per-repo CI design on `main` and the enterprise-wide design on `feature/enterprise-sbom-platform`.

## Context

The team needs to know what each of the org's repositories depends on, see the known vulnerabilities and licences in those dependencies, and answer "where do we use package X?" quickly during an incident.

The earlier design on `main` made each repo upload its own SBOM from CI, so coverage depended on every repo adding a job. GitHub already builds an SBOM for every repository from its dependency graph. The platform is for one team and one org, with as little to run as possible.

## Decision

1. **Use GitHub's dependency-graph SBOM as the source.** An org security configuration (`cps-sbom-baseline`) turns the graph on for every repo. A read-only, org-owned GitHub App fetches the SBOMs.
2. **Run one collector:** an Azure Function on Flex Consumption.
   - Each night it queues the repos that changed, plus a rolling seventh of the rest.
   - It fetches each SBOM through GitHub's asynchronous export API, archives it to Blob for 13 months, converts it to CycloneDX and loads it into Dependency-Track.
3. **Use Dependency-Track as the only dashboard.** It re-checks every component against new vulnerabilities continuously, applies licence policies, records triage decisions, and searches components across all projects. DefectDojo and Sentinel aren't used.
4. **Keep it to one team with two roles.** `sg-sbom-cps-admins` administers Dependency-Track and `sg-sbom-cps-users` triages findings. Portfolio access control is off, so everyone who can sign in sees every project.
5. **No private networking.** Every service uses its public endpoint and authenticates every caller.
6. **Cover Terraform from CI.** The dependency graph has no Terraform support, so Terraform repos keep a CI job (`sbom-scan.yml`).
7. **Deploy with Terraform from GitHub Actions**, from `main` only, using OIDC.

## Security model

| Service | Reachable from | Protected by |
|---|---|---|
| Storage | Internet | Shared keys off; Entra ID and a data role on every call |
| Key Vault | Internet | Entra ID and RBAC |
| Postgres | Azure services only | Generated password, TLS required |
| Dependency-Track API | Internet | An API key or a signed-in session on every call |
| Dependency-Track UI | `allowed_ip_ranges` | Sign-in |

The API can't be IP-restricted. The Function has no fixed outbound IP without a VNet and NAT gateway, and people's browsers call the API directly from the UI.

The only long-lived secrets are the GitHub App key and the two Dependency-Track API keys, all in Key Vault. The one storage account with a key, `stdtrack<env>`, holds only Dependency-Track's rebuildable caches, because Container Apps file mounts require a key.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Per-repo CI uploads (`main`) | Coverage depends on every repo adding a job, and nothing shows which repos haven't |
| Enterprise-wide, with Sentinel and private endpoints | Built for a wider scope than this team needs. It needs landing-zone subnets, private DNS and a jump box. |
| VNet and NAT gateway for the Function only | About £30 a month and a network to run, to restrict an API that already needs a key. Revisit if the API must not be internet-facing, or if GitHub IP allow lists are enforced. |
| Keep DefectDojo | A second self-hosted app with its own database, for cross-tool aggregation this design doesn't need |

## Consequences

**Benefits**
- Every non-archived repo in the org is covered, with no per-repo setup.
- New CVEs show up against old SBOMs without re-collecting.
- 38 Azure resources, with no network to manage.

**Accepted risks**
- **A Dependency-Track vulnerability would be exposed to the internet.** Patch within 7 days of a security release.
- **SBOMs show the default branch**, which isn't necessarily what's deployed. `release-sbom-attest.yml` covers services that adopt it.
- **Some repos show `no-dependency-graph`:** those without lockfiles, or in unsupported ecosystems.
- **Dependency-Track runs as one replica**, so the UI is down briefly during patching. The data is safe in Postgres and Blob.
- **GitHub allows 100 SBOMs an hour**, so a large org's first collection takes several hours.
