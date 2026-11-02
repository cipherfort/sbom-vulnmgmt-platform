locals {
  # Names follow the design doc (rg-sbom-prd, kv-sbom-prd, ...). Key Vault
  # and storage account names are globally unique — if a plan fails on a
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

# Created in bootstrap (deployment runbook step 6) so the deployer's Contributor and RBAC
# Administrator roles can be scoped to this group alone.
data "azurerm_resource_group" "this" {
  name = "rg-sbom-${local.env}"
}

# N4: data stays in a UK region. Everything takes the resource group's
# location, so this one check covers all of it.
check "uk_region" {
  assert {
    condition     = contains(["uksouth", "ukwest"], data.azurerm_resource_group.this.location)
    error_message = "rg-sbom-${local.env} must be in uksouth or ukwest (requirement N4)."
  }
}

data "azurerm_client_config" "current" {}
