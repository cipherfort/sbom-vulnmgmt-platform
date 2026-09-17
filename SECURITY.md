# Security Policy

## Supported versions

This is infrastructure-as-code, not a versioned library — there's no concept of "supported" older releases. Security fixes land on `main` and the latest tag; if you're running an older tag, update to the latest one.

## Reporting a vulnerability

If you find something that looks like a security vulnerability in this repo's Terraform, GitHub Actions workflows, or bootstrap scripts, please report it privately via GitHub's security advisory feature (this repo's Security tab → **Report a vulnerability**) rather than opening a public issue.

## Scope

**In scope:**
- Terraform in `modules/platform/` and `examples/standalone/` — e.g. a misconfiguration that could expose secrets, weaken network isolation, or grant broader access than intended.
- The reusable GitHub Actions workflows (`sbom-scan.yml`, `image-scan.yml`, `secret-scan.yml`, `sast-scan.yml`, `cd.yml`, `terraform-ci.yml`).
- `scripts/bootstrap.sh` / `scripts/teardown-bootstrap.sh`.

**Out of scope** (report upstream instead):
- Vulnerabilities in Dependency-Track, DefectDojo, PostgreSQL, or Redis themselves — those are separate upstream projects with their own security processes.
- Vulnerabilities in third-party GitHub Actions this repo calls (`aquasecurity/trivy-action`, `anchore/scan-action`, etc.) — report to those projects directly.

## Response expectations

This is a personal open-source project without a dedicated security team — response is best-effort, not covered by an SLA. Genuine vulnerabilities will be prioritized over feature work.
