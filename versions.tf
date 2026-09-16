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

  # Storage account referenced here must exist before `terraform init` —
  # see README "Bootstrap" step 1. Placeholder names below.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-security-platform"
    storage_account_name = "stsecplatstate001"
    container_name       = "terraform-state"
    key                  = "security-platform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}
