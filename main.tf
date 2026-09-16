resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name_prefix}"
  location = var.location

  tags = {
    environment = "platform"
    managed_by  = "terraform"
    repo        = "sbom-vulnmgmt-platform"
  }
}

data "azurerm_client_config" "current" {}
