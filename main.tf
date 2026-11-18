locals {
  env = var.environment
  sfx = var.global_name_suffix

  tags = {
    environment         = local.env
    managed_by          = "terraform"
    repo                = "cps-security-platform-infra"
    data_classification = "OFFICIAL-SENSITIVE"
  }
}

# Created by hand, so the deployer's roles can be scoped to it.
data "azurerm_resource_group" "this" {
  name = "rg-sbom-${local.env}"
}

# Everything takes the resource group's location, so this keeps all data in the UK.
check "uk_region" {
  assert {
    condition     = contains(["uksouth", "ukwest"], data.azurerm_resource_group.this.location)
    error_message = "rg-sbom-${local.env} must be in uksouth or ukwest."
  }
}

data "azurerm_client_config" "current" {}
