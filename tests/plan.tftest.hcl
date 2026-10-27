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
      default_domain    = "kindstone-1234abcd.uksouth.azurecontainerapps.io"
      static_ip_address = "10.0.0.10"
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
  mock_resource "azurerm_monitor_data_collection_rule" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sbom-prd/providers/Microsoft.Insights/dataCollectionRules/dcr-sbom-prd"
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
  vnet_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lz/providers/Microsoft.Network/virtualNetworks/vnet-lz"
  function_subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lz/providers/Microsoft.Network/virtualNetworks/vnet-lz/subnets/func"
  container_apps_subnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lz/providers/Microsoft.Network/virtualNetworks/vnet-lz/subnets/cae"
  private_endpoint_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lz/providers/Microsoft.Network/virtualNetworks/vnet-lz/subnets/pe"
  private_dns_zone_ids = {
    vault    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
    blob     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    queue    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net"
    table    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net"
    file     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net"
    postgres = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  }
  cps_workspace_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sentinel/providers/Microsoft.OperationalInsights/workspaces/law-cps"
  github_enterprise_slug = "cps"
  github_app_id          = "123456"
  alert_email            = "cps-platform@example.org"
}

run "phase1_defaults" {
  command = plan

  assert {
    condition     = length(local.dtrack_api_oidc_env) == 0
    error_message = "OIDC must stay off until an Entra app exists"
  }
  assert {
    condition     = azurerm_storage_account.sbom.shared_access_key_enabled == false
    error_message = "Collector storage must have shared keys off (N1)"
  }
  assert {
    condition     = length(azurerm_sentinel_watchlist_item.banned_packages) == 0
    error_message = "No watchlist rows by default"
  }
}

run "phase2_entra_and_watchlist" {
  command = plan

  variables {
    manage_entra    = true
    sbom_orgs       = ["cps", "team-a"]
    banned_packages = [{ PackageName = "event-stream", Reason = "test" }]
  }

  assert {
    condition     = length(azuread_group.sbom) == 3
    error_message = "One admin group plus one group per org"
  }
  assert {
    condition     = contains(keys(azuread_group.sbom), "sg-sbom-org-team-a")
    error_message = "Org groups follow sg-sbom-org-<org>, the name dtrack.py's ORG_TEAM expects"
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
