# Contributing

Thanks for considering a contribution.

## Proposing a change

Fork the repo, create a branch, and open a pull request against `main`. Small, focused PRs are easier to review than large ones — if you're planning something substantial, opening an issue first to discuss the approach is a good idea.

## Before submitting a PR

```bash
terraform fmt -recursive -check -diff .   # formatting, from repo root

# This repo has two Terraform roots — the reusable module and the
# deployable example that calls it — each needs its own init/validate:
(cd modules/platform && terraform init -backend=false && terraform validate)
(cd examples/standalone && terraform init -backend=false && terraform validate)
```

All three should pass cleanly.

## Testing changes

There's no automated test suite for this infrastructure — that's a real gap, not a deliberate choice. The honest way to validate a change is `terraform plan` (and ideally `terraform apply`) against a scratch/sandbox Azure subscription, not just by reading the diff. If your change touches resource sizing, networking, or the DefectDojo/Dependency-Track container configs, please say in the PR description what you actually tested and how.

## Commit style

Short, imperative summary line (e.g. "Fix Redis clustering policy for Celery compatibility"), with a body explaining *why* when the reasoning isn't obvious from the diff.

## Reporting a security issue

See [SECURITY.md](SECURITY.md).

## Code of conduct

Be respectful and constructive in issues, PRs, and discussions. This project doesn't have a separate code of conduct document at this size — just don't be a jerk.
