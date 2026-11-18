terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.60"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    azuread = {
      source  = "hashicorp/azuread" # only used when manage_entra = true
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  # Change these to your state storage account (docs/deployment-runbook.md).
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-security-platform"
    storage_account_name = "stsecplatstate001"
    container_name       = "terraform-state"
    key                  = "sbom-platform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  # The collector storage account has shared keys turned off.
  storage_use_azuread = true

  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azapi" {}

provider "azuread" {}
