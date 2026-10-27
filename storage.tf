# ---------- stsbomprd: raw SBOM archive, work queue, state table ----------

resource "azurerm_storage_account" "sbom" {
  name                     = "stsbom${local.env}${local.sfx}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  min_tls_version          = "TLS1_2"
  tags                     = local.tags

  # No keys anywhere (N1): every caller uses Entra ID.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false

  blob_properties {
    # F2: history of what each repo contained. Versioning keeps overwritten
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

resource "azurerm_storage_table" "repostate" {
  name               = "repostate"
  storage_account_id = azurerm_storage_account.sbom.id
}

# Raw SBOM retention: 13 months, Cool after 30 days (decision table, §10).
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

resource "azurerm_private_endpoint" "sbom" {
  for_each = toset(["blob", "queue", "table"])

  name                = "pe-stsbom-${each.key}-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = each.key
    private_connection_resource_id = azurerm_storage_account.sbom.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids[each.key]]
  }
}

# ---------- stdtrackprd: Dependency-Track /data ----------
#
# Deliberate exception to "no keys": a Container Apps Azure Files mount only
# supports account-key auth. The key lives in the environment's storage
# config only; the account is private-endpoint-only and holds nothing but
# Dependency-Track's mirror cache and search indexes (all rebuildable).

resource "azurerm_storage_account" "dtrack" {
  name                          = "stdtrack${local.env}${local.sfx}"
  resource_group_name           = data.azurerm_resource_group.this.name
  location                      = data.azurerm_resource_group.this.location
  account_tier                  = "Standard"
  account_replication_type      = "ZRS"
  min_tls_version               = "TLS1_2"
  public_network_access_enabled = false
  tags                          = local.tags
}

resource "azurerm_storage_share" "dtrack_data" {
  name               = "dtrack-data"
  storage_account_id = azurerm_storage_account.dtrack.id
  quota              = 100
}

resource "azurerm_private_endpoint" "dtrack_file" {
  name                = "pe-stdtrack-file-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "file"
    private_connection_resource_id = azurerm_storage_account.dtrack.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["file"]]
  }
}
