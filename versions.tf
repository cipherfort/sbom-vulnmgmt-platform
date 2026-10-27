terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # 4.x line. azurerm_function_app_flex_consumption and the
      # storage_account_id (management-plane) form of storage containers,
      # queues and tables need a recent 4.x — those matter here because the
      # storage accounts have public access off, so the deployer can't use
      # the data plane.
      version = "~> 4.60"
    }
    azapi = {
      source = "Azure/azapi"
      # Custom Log Analytics tables with an explicit column schema — azurerm
      # has no resource for that.
      version = "~> 2.0"
    }
    azuread = {
      source = "hashicorp/azuread"
      # Phase 2 Entra groups and the Dependency-Track app registration.
      # Only used when var.manage_entra is true.
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  # Storage account referenced here must exist before `terraform init` —
  # see README "Bootstrap" step 1. New state key: this is a rebuild, not an
  # in-place change of the old rg-security-platform stack, so the first
  # apply can't destroy that stack by accident. Decommissioning it is an
  # explicit checklist step in docs/enterprise-sbom/delivery-plan.md.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-security-platform"
    storage_account_name = "stsecplatstate001"
    container_name       = "terraform-state"
    key                  = "sbom-platform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  # Shared-key access is off on the collector storage account, so any
  # data-plane call the provider makes must use Entra ID.
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
