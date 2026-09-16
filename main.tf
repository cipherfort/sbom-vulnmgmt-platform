resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "this" {
  name     = "rg-security-platform"
  location = var.location

  tags = {
    environment = "platform"
    managed_by  = "terraform"
    repo        = "cps-security-platform-infra"
  }
}

data "azurerm_client_config" "current" {}
