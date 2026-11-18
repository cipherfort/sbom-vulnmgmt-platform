resource "azurerm_postgresql_flexible_server" "dtrack" {
  name                = "psql-dtrack-${local.env}${local.sfx}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = local.tags

  sku_name   = "B_Standard_B2s"
  storage_mb = 32768
  version    = "16"

  administrator_login    = "dtrackadmin"
  administrator_password = random_password.postgres_admin.result

  public_network_access_enabled = true

  zone                         = "1"
  backup_retention_days        = 14
  geo_redundant_backup_enabled = false

  lifecycle {
    # Azure can move the server to another zone after a failover.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "dtrack" {
  name      = "dtrack"
  server_id = azurerm_postgresql_flexible_server.dtrack.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# Azure's "allow Azure services" rule: Dependency-Track has no fixed outbound IP.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.dtrack.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
