resource "azurerm_key_vault" "this" {
  name                       = "kv-sbom-${local.env}${local.sfx}"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = data.azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
  tags                       = local.tags

  # Private endpoint only, unless the deployer needs a firewall hole to
  # write the Postgres password below (see var.deployer_ip_ranges).
  public_network_access_enabled = length(var.deployer_ip_ranges) > 0

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.deployer_ip_ranges
  }
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-kv-sbom-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "kv"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["vault"]]
  }
}

# The deploying identity (CI's OIDC service principal) writes the secrets
# Terraform generates. The GitHub App private keys and the Dependency-Track
# API key are NOT created here — they're added by hand so they never sit in
# Terraform state (see docs/enterprise-sbom/delivery-plan.md, Phase 1).
resource "azurerm_role_assignment" "deployer_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "random_password" "postgres_admin" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "postgres_admin_password" {
  name         = "postgres-admin-password"
  value        = random_password.postgres_admin.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin, azurerm_private_endpoint.kv]
}
