# ---------- stsbom<env>: raw SBOM archive, work queue, state table ----------

resource "azurerm_storage_account" "sbom" {
  name                     = "stsbom${local.env}${local.sfx}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  min_tls_version          = "TLS1_2"
  tags                     = local.tags

  # No keys: every caller uses Entra ID. The public endpoint stays on
  # because the Function has no fixed outbound IP to allow through a
  # firewall; without a key, a caller still needs a data role here.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false

  blob_properties {
    # History of what each repo contained. Versioning keeps overwritten
    # same-day blobs too.
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }
  }
}

resource "azurerm_storage_container" "sbom_raw" {
  name               = "sbom-raw"
  storage_account_id = azurerm_storage_account.sbom.id
}

# Flex Consumption pulls its deployment package from a blob container.
resource "azurerm_storage_container" "deployments" {
  name               = "function-deployments"
  storage_account_id = azurerm_storage_account.sbom.id
}

resource "azurerm_storage_queue" "sbom_work" {
  name               = "sbom-work"
  storage_account_id = azurerm_storage_account.sbom.id
}

# The Functions host creates sbom-work-poison on first poison message, but
# report_poison_depth peeks it every 15 minutes — create it up front so that
# timer never hits a missing queue.
resource "azurerm_storage_queue" "sbom_work_poison" {
  name               = "sbom-work-poison"
  storage_account_id = azurerm_storage_account.sbom.id
}

# azapi, not azurerm_storage_table: azurerm (4.81) creates tables over the data
# plane even with storage_account_id, so the deployer would need a table data
# role. This goes through ARM, which Contributor covers.
resource "azapi_resource" "repostate" {
  type      = "Microsoft.Storage/storageAccounts/tableServices/tables@2024-01-01"
  name      = "repostate"
  parent_id = "${azurerm_storage_account.sbom.id}/tableServices/default"
}

# Raw SBOM retention: 13 months, Cool after 30 days.
resource "azurerm_storage_management_policy" "sbom" {
  storage_account_id = azurerm_storage_account.sbom.id

  rule {
    name    = "sbom-raw-retention"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["sbom-raw/"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = 30
        delete_after_days_since_modification_greater_than       = 395
      }
      version {
        change_tier_to_cool_after_days_since_creation = 30
        delete_after_days_since_creation              = 395
      }
    }
  }
}

# ---------- stdtrack<env>: Dependency-Track /data ----------
#
# Deliberate exception to "no keys": a Container Apps Azure Files mount only
# supports account-key auth. The key lives in the environment's storage
# config only, and the account holds nothing but Dependency-Track's mirror
# cache and search indexes (all rebuildable).

resource "azurerm_storage_account" "dtrack" {
  name                            = "stdtrack${local.env}${local.sfx}"
  resource_group_name             = data.azurerm_resource_group.this.name
  location                        = data.azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

resource "azurerm_storage_share" "dtrack_data" {
  name               = "dtrack-data"
  storage_account_id = azurerm_storage_account.dtrack.id
  quota              = 100
}
