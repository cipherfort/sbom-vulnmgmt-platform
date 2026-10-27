resource "azurerm_postgresql_flexible_server" "dtrack" {
  name                = "psql-dtrack-${local.env}${local.sfx}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = local.tags

  sku_name   = "GP_Standard_D2ds_v5"
  storage_mb = 65536
  version    = "16"

  administrator_login    = "dtrackadmin"
  administrator_password = random_password.postgres_admin.result

  # Reached only through the private endpoint below.
  public_network_access_enabled = false

  zone                         = "1"
  backup_retention_days        = 14
  geo_redundant_backup_enabled = false

  lifecycle {
    # Azure may move the server to another zone after a failover.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "dtrack" {
  name      = "dtrack"
  server_id = azurerm_postgresql_flexible_server.dtrack.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

resource "azurerm_private_endpoint" "postgres" {
  name                = "pe-psql-dtrack-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "postgres"
    private_connection_resource_id = azurerm_postgresql_flexible_server.dtrack.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["postgres"]]
  }
}
