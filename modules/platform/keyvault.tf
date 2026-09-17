resource "azurerm_key_vault" "this" {
  name                       = "kv-${var.name_prefix}-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  # Deliberately NOT public_network_access_enabled = false here, unlike
  # Postgres. Postgres databases are managed entirely through the ARM
  # control plane (azurerm_postgresql_flexible_server_database never speaks
  # the Postgres wire protocol), so disabling its public network access
  # doesn't affect Terraform's own ability to manage it. Key Vault secrets
  # (azurerm_key_vault_secret) are a DATA-plane API
  # (https://<vault>.vault.azure.net/...) — fully disabling public access
  # would mean `terraform apply` itself could only run from inside the VNet.
  # An IP allowlist (reusing the same ranges already used for Container
  # Apps ingress) blocks the random internet while keeping this deployable
  # from wherever you already run Terraform from. The private endpoint
  # below gives the VNet-integrated Container Apps Environment its own,
  # separate access path regardless of this firewall.
  dynamic "network_acls" {
    for_each = var.enable_private_networking ? [1] : []
    content {
      default_action = "Deny"
      bypass         = "AzureServices"
      ip_rules       = var.allowed_ip_ranges
    }
  }
}

# The deploying identity (CI's OIDC service principal, or whoever runs
# `terraform apply` locally) needs to write secrets below.
resource "azurerm_role_assignment" "deployer_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "random_password" "defectdojo_secret_key" {
  length  = 50
  special = false
}

resource "random_password" "defectdojo_credential_aes_key" {
  length  = 32
  special = false
}

resource "random_password" "defectdojo_admin" {
  length  = 20
  special = true
}

resource "azurerm_key_vault_secret" "defectdojo_secret_key" {
  name         = "defectdojo-secret-key"
  value        = random_password.defectdojo_secret_key.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin]
}

resource "azurerm_key_vault_secret" "defectdojo_credential_aes_key" {
  name         = "defectdojo-credential-aes-key"
  value        = random_password.defectdojo_credential_aes_key.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin]
}

resource "azurerm_key_vault_secret" "defectdojo_admin_password" {
  name         = "defectdojo-admin-password"
  value        = random_password.defectdojo_admin.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin]
}

# Dependency-Track has no first-run admin env var — it ships with a default
# admin/admin login that forces a password change on first login. Nothing to
# seed here; see README "First login" steps.
