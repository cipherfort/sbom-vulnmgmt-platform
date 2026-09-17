## What does this change and why?

<!-- A sentence or two on the change and the motivation behind it. -->

## Checklist

- [ ] `terraform fmt -check -recursive -diff .` passes
- [ ] `terraform validate` passes in both `modules/platform/` and `examples/standalone/` (`terraform init -backend=false && terraform validate` in each)
- [ ] Linked issue, if any: closes #

## What did you actually test this against?

<!--
Be specific — this is infrastructure, and "it validates" isn't the same as
"it works." Did you run `terraform plan`/`apply` against a real Azure
subscription? Which optional flags were enabled (name_prefix,
enable_private_networking, high_availability_enabled)? If you didn't test
against real Azure, say so explicitly so reviewers know to apply extra
scrutiny.
-->
