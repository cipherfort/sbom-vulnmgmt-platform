# Plans the whole configuration against mocked providers — catches cycles,
# bad references and for_each-on-unknown errors without Azure credentials.
#   terraform init -backend=false && terraform test

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      location = "uksouth"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }
  mock_resource "azurerm_container_app_environment" {
    defaults = {
      default_domain = "kindstone-1234abcd.uksouth.azurecontainerapps.io"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sbom-prd/providers/Microsoft.KeyVault/vaults/kv-sbom-prd"
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sbom-prd/providers/Microsoft.Storage/storageAccounts/stsbomprd"
    }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sbom-prd/providers/Microsoft.OperationalInsights/workspaces/log-sbom-prd"
    }
  }
  mock_resource "azurerm_application_insights" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sbom-prd/providers/Microsoft.Insights/components/appi-sbom-prd"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sbom-prd/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id"
    }
  }
}
mock_provider "azapi" {}
mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      object_id = "00000000-0000-0000-0000-000000000003"
    }
  }
  mock_resource "azuread_application" {
    override_during = plan
    defaults = {
      client_id = "00000000-0000-0000-0000-000000000004"
    }
  }
}
mock_provider "random" {}

variables {
  github_app_id = "123456"
  alert_email   = "cps-platform@example.org"
}

run "defaults" {
  command = plan

  assert {
    condition     = length(local.dtrack_api_oidc_env) == 0
    error_message = "OIDC must stay off until an Entra app exists"
  }
  assert {
    condition     = azurerm_storage_account.sbom.shared_access_key_enabled == false
    error_message = "Collector storage must have shared keys off"
  }
  assert {
    condition     = length(azurerm_container_app.dtrack_ui.ingress[0].ip_security_restriction) == 0
    error_message = "No UI IP restriction unless allowed_ip_ranges is set"
  }
}

run "ui_ip_restriction" {
  command = plan

  variables {
    allowed_ip_ranges = ["203.0.113.0/24", "198.51.100.10/32"]
  }

  assert {
    condition     = length(azurerm_container_app.dtrack_ui.ingress[0].ip_security_restriction) == 2
    error_message = "One UI allow rule per allowed_ip_ranges entry"
  }
  assert {
    condition     = length(azurerm_container_app.dtrack_api.ingress[0].ip_security_restriction) == 0
    error_message = "The API must stay open: the collector has no fixed outbound IP"
  }
}

run "entra" {
  command = plan

  variables {
    manage_entra = true
  }

  assert {
    condition     = toset(keys(azuread_group.sbom)) == toset(["sg-sbom-cps-admins", "sg-sbom-cps-users"])
    error_message = "Groups must match the team names dtrack_admin.py bootstrap maps"
  }
  assert {
    condition     = length(local.dtrack_api_oidc_env) == 7
    error_message = "OIDC settings appear once the app registration is managed here"
  }
}

run "rejects_invalid_name_suffix" {
  command = plan

  variables {
    global_name_suffix = "BAD-1"
  }
  expect_failures = [var.global_name_suffix]
}
