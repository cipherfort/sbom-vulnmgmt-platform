# RBAC only, public endpoint: every caller (the Function, Container Apps'
# secret reference, the deployer, admins) signs in with Entra ID and needs a
# role on this vault. The Function has no fixed outbound IP, so there is no
# firewall to put in front of it.
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

  # Explicit, so a vault recovered from soft delete (same name redeployed)
  # loses any firewall it had before.
  public_network_access_enabled = true
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

# The deploying identity (CI's OIDC service principal) writes the secrets
# Terraform generates. The GitHub App private key and the Dependency-Track
# API keys are NOT created here — they're added by hand or by
# ops/first_setup.py, so they never sit in Terraform state.
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
  depends_on   = [azurerm_role_assignment.deployer_kv_admin]
}
