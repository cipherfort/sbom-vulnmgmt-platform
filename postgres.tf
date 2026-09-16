resource "random_password" "postgres_admin" {
  length  = 24
  special = false
}

resource "azurerm_key_vault_secret" "postgres_admin_password" {
  name         = "postgres-admin-password"
  value        = random_password.postgres_admin.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin]
}

# One server, two databases — keeps MVP cost down. Split into separate
# servers later if DT/DefectDojo load or blast-radius isolation calls for it.
resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${var.name_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768
  version    = "16"

  administrator_login    = "secplatadmin"
  administrator_password = random_password.postgres_admin.result

  zone                         = "1"
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
}

resource "azurerm_postgresql_flexible_server_database" "dtrack" {
  name      = "dtrack"
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

resource "azurerm_postgresql_flexible_server_database" "defectdojo" {
  name      = "defectdojo"
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# MVP: Container Apps without a custom VNet integration doesn't have a fixed
# egress IP, so the pragmatic default is "allow Azure services" rather than a
# tight IP rule here. Tighten by moving both the Container Apps environment
# and this server onto the same VNet with private endpoints — see README
# "Networking hardening".
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
