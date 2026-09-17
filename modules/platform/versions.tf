terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Pinned to the 4.x line — azurerm 5.x renames several arguments used
      # here (e.g. enable_rbac_authorization -> rbac_authorization_enabled).
      # Bump deliberately and update those references if you move to 5.x.
      version = "~> 4.12"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
