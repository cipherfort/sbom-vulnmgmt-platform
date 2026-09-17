# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.0] - 2026-09-17

Initial public release.

### Added

- Terraform deploying **Dependency-Track** + **DefectDojo** on Azure Container Apps, sharing one PostgreSQL Flexible Server and one Key Vault, with all credentials generated at deploy time and never committed to git.
- Reusable GitHub Actions workflows other repos call to onboard: `sbom-scan.yml` (Terraform/npm SBOM ingestion), `image-scan.yml` (Trivy + Grype container scanning), `secret-scan.yml` (Gitleaks), `sast-scan.yml` (Semgrep) — all dual-writing SARIF to both the calling repo's GitHub Security tab and DefectDojo.
- `name_prefix` variable so multiple deployments can coexist in one subscription/tenant without name collisions.
- `enable_private_networking` — moves PostgreSQL and Key Vault onto a VNet with private endpoints (public access disabled on Postgres, IP-allowlisted on Key Vault) while keeping Container Apps ingress public so GitHub-hosted CI runners keep working.
- `high_availability_enabled` — zone-redundant PostgreSQL and 2 replicas on every Container App.
- Restructured into `modules/platform/` (a reusable Terraform module, no backend/provider config) and `examples/standalone/` (the deployable root most people want), so this can be composed into other Terraform instead of only cloned wholesale.
- `scripts/bootstrap.sh` / `scripts/teardown-bootstrap.sh` automating the manual Azure OIDC/RBAC bootstrap steps, and `examples/consumer-workflows/{ci,cd}.yml` as ready-to-copy onboarding files.
- CI (`terraform-ci.yml`) validating this repo's own Terraform on every PR: fmt, validate, tflint, and a Checkov self-scan — none requiring Azure credentials, so it runs safely on PRs from forks.
- Standard OSS project files: `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, issue/PR templates, `CODEOWNERS`.
- `docs/ARCHITECTURE.md` covering the tool-landscape comparison, data flow, and deployment rationale; `docs/how-to-use.md` covering day-to-day operation and onboarding.

### Fixed

Real bugs found only by actually deploying this repeatedly against a live Azure subscription, not visible from reading the Terraform:

- Azure Managed Redis needs `clustering_policy = "NoCluster"` — the default cluster-sharded mode breaks Celery's Redis client with `MOVED`/`CROSSSLOT` errors.
- Dependency-Track's apiserver hard-refuses to start below a 4GB JVM heap; needed explicit `EXTRA_JAVA_OPTIONS=-Xmx4g` plus a container memory bump, since default container-aware JVM sizing never gets there on its own.
- DefectDojo was missing its database migration step entirely — added an `init_container` running the upstream image's initializer entrypoint.
- An `EmptyDir` volume mounted at nginx's static-files path was shadowing files the DefectDojo nginx image bakes in at build time, serving an unstyled page.
- A Consumption-only Container Apps Environment's infrastructure subnet must be delegated to `Microsoft.App/environments` once VNet-integrated — contrary to Microsoft's own general documentation, which describes this delegation as forbidden for Consumption-only environments.
- VNet integration silently upgrades the environment to workload-profile status; Azure auto-attaches a default "Consumption" profile that must be declared explicitly or every subsequent `terraform plan` shows spurious drift trying to remove it.
- PostgreSQL HA is rejected outright on the Burstable SKU tier by the live provisioning API, despite the SKU capability-listing API generically listing `ZoneRedundant` as a supported HA mode for it.
- Postgres's `standby_availability_zone` is Optional but not Computed in the provider schema — leaving it unset causes a perpetual invalid modify against whatever zone Azure actually assigned.
