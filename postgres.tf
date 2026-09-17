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

  # HA requires swapping off the Burstable SKU — confirmed against the real
  # Azure API, which rejects it outright ("HANotSupportedForBurstableSku...
  # High availability not supported for burstable server"), despite `az
  # postgres flexible-server list-skus` generically listing ZoneRedundant
  # as a supported HA mode for Standard_B1ms in this capability schema.
  # That capability listing doesn't validate this specific SKU+HA
  # combination — trust the provisioning-time rejection, not the schema.
  sku_name   = var.high_availability_enabled ? "GP_Standard_D2s_v3" : "B_Standard_B1ms"
  storage_mb = 32768
  version    = "16"

  administrator_login    = "secplatadmin"
  administrator_password = random_password.postgres_admin.result

  zone                         = "1"
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  delegated_subnet_id           = var.enable_private_networking ? azurerm_subnet.postgres[0].id : null
  private_dns_zone_id           = var.enable_private_networking ? azurerm_private_dns_zone.postgres[0].id : null
  public_network_access_enabled = !var.enable_private_networking

  # standby_availability_zone must be set explicitly, even though it's
  # Optional in the schema — it's not Computed, so leaving it unset makes
  # Terraform treat "unset" as "should be null" on every subsequent plan,
  # generating a perpetual invalid modify against whatever zone Azure
  # actually assigned (confirmed via a real apply: the resulting error is
  # "an existing high_availability.0.standby_availability_zone can only be
  # changed when exchanged with the zone specified in zone").
  dynamic "high_availability" {
    for_each = var.high_availability_enabled ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = "2"
    }
  }
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
# tight IP rule here. Meaningless once enable_private_networking disables
# public access entirely, hence the count below.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  count            = var.enable_private_networking ? 0 : 1
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
