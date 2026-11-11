terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # 4.x line. azurerm_function_app_flex_consumption and the
      # storage_account_id (management-plane) form of storage containers and
      # queues need a recent 4.x — they let the deployer create them without
      # a storage data-plane role.
      version = "~> 4.60"
    }
    azapi = {
      source = "Azure/azapi"
      # The repostate table over ARM: azurerm_storage_table uses the data
      # plane, which would need a storage data role on the deployer.
      version = "~> 2.0"
    }
    azuread = {
      source = "hashicorp/azuread"
      # Entra groups and the Dependency-Track app registration. Only used
      # when var.manage_entra is true.
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  # Storage account referenced here must exist before `terraform init` —
  # see docs/deployment-runbook.md, step 3. Its own state key, so an apply
  # can never touch the old rg-security-platform stack from main.
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
