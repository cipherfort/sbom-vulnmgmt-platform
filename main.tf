locals {
  # Names follow rg-sbom-<env>, kv-sbom-<env>, ... Key Vault, storage
  # account and Postgres names are globally unique — if a plan fails on a
  # name clash, set var.global_name_suffix rather than renaming here.
  env = var.environment
  sfx = var.global_name_suffix

  tags = {
    environment         = local.env
    managed_by          = "terraform"
    repo                = "cps-security-platform-infra"
    data_classification = "OFFICIAL-SENSITIVE"
  }
}

# Created in bootstrap (deployment runbook step 5) so the deployer's Contributor and RBAC
# Administrator roles can be scoped to this group alone.
data "azurerm_resource_group" "this" {
  name = "rg-sbom-${local.env}"
}

# Data stays in a UK region. Everything takes the resource group's
# location, so this one check covers all of it.
check "uk_region" {
  assert {
    condition     = contains(["uksouth", "ukwest"], data.azurerm_resource_group.this.location)
    error_message = "rg-sbom-${local.env} must be in uksouth or ukwest."
  }
}

data "azurerm_client_config" "current" {}
