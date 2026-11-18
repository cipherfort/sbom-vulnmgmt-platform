# Raw SBOM archive, work queue and state table.
resource "azurerm_storage_account" "sbom" {
  name                     = "stsbom${local.env}${local.sfx}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  min_tls_version          = "TLS1_2"
  tags                     = local.tags

  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false

  blob_properties {
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

# Holds the Function's code package.
resource "azurerm_storage_container" "deployments" {
  name               = "function-deployments"
  storage_account_id = azurerm_storage_account.sbom.id
}

resource "azurerm_storage_queue" "sbom_work" {
  name               = "sbom-work"
  storage_account_id = azurerm_storage_account.sbom.id
}

# Created up front because report_poison_depth reads it before any message fails.
resource "azurerm_storage_queue" "sbom_work_poison" {
  name               = "sbom-work-poison"
  storage_account_id = azurerm_storage_account.sbom.id
}

# azapi because azurerm_storage_table needs a data role on the deployer.
resource "azapi_resource" "repostate" {
  type      = "Microsoft.Storage/storageAccounts/tableServices/tables@2024-01-01"
  name      = "repostate"
  parent_id = "${azurerm_storage_account.sbom.id}/tableServices/default"
}

# Cool after 30 days, deleted after 13 months.
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

# Dependency-Track's /data share. It keeps an account key because Container
# Apps file mounts only support keys; it holds only rebuildable caches.
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
