locals {
  # Entra-ID-only connections (the storage account has shared keys off).
  # __credential/__clientId make the Functions host use the user-assigned
  # identity rather than looking for a system-assigned one.
  collector_identity_conn = {
    credential = "managedidentity"
    clientId   = azurerm_user_assigned_identity.collector.client_id
  }

  collector_app_settings = merge(
    {
      # azurerm writes AzureWebJobsStorage as a connection string with an empty
      # AccountKey, which wins over the identity settings below: the host then
      # can't reach storage, so host keys and timer leases fail. Empty = unset.
      AzureWebJobsStorage              = ""
      AzureWebJobsStorage__accountName = azurerm_storage_account.sbom.name
      SbomStorage__queueServiceUri     = azurerm_storage_account.sbom.primary_queue_endpoint
    },
    { for k, v in local.collector_identity_conn : "AzureWebJobsStorage__${k}" => v },
    { for k, v in local.collector_identity_conn : "SbomStorage__${k}" => v },
    {
      # DefaultAzureCredential in function_app.py picks the user-assigned
      # identity from this.
      AZURE_CLIENT_ID = azurerm_user_assigned_identity.collector.client_id

      APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "ClientId=${azurerm_user_assigned_identity.collector.client_id};Authorization=AAD"

      GITHUB_APP_ID        = var.github_app_id
      KEY_VAULT_URL        = azurerm_key_vault.this.vault_uri
      SBOM_STORAGE_ACCOUNT = azurerm_storage_account.sbom.name
      DTRACK_URL           = "https://${azurerm_container_app.dtrack_api.ingress[0].fqdn}"
    },
  )
}

resource "azurerm_user_assigned_identity" "collector" {
  name                = "id-sbom-collector-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = local.tags
}

# Least privilege. Blob Data Owner
# (not Contributor) is what the Functions host needs for its blob leases on
# AzureWebJobsStorage.
resource "azurerm_role_assignment" "collector" {
  for_each = {
    kv_secrets_user = { scope = azurerm_key_vault.this.id, role = "Key Vault Secrets User" }
    blob_owner      = { scope = azurerm_storage_account.sbom.id, role = "Storage Blob Data Owner" }
    queue           = { scope = azurerm_storage_account.sbom.id, role = "Storage Queue Data Contributor" }
    table           = { scope = azurerm_storage_account.sbom.id, role = "Storage Table Data Contributor" }
    appi_publisher  = { scope = azurerm_application_insights.collector.id, role = "Monitoring Metrics Publisher" }
  }

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.collector.principal_id
}

resource "azurerm_application_insights" "collector" {
  name                = "appi-sbom-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "other"
  tags                = local.tags

  # Telemetry is sent with the managed identity only.
  local_authentication_enabled = false
}

resource "azurerm_service_plan" "collector" {
  name                = "asp-sbom-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

resource "azurerm_function_app_flex_consumption" "collector" {
  name                = "func-sbom-${local.env}${local.sfx}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  service_plan_id     = azurerm_service_plan.collector.id
  tags                = local.tags

  runtime_name    = "python"
  runtime_version = "3.11"

  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.sbom.primary_blob_endpoint}${azurerm_storage_container.deployments.name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.collector.id

  # The cap applies per function, so collect_sbom never runs on more than
  # 4 instances x (batchSize 8 + newBatchThreshold 4) = 48 concurrent
  # GitHub calls — well under GitHub's ~100 concurrent-request secondary
  # limit, leaving room for other automation.
  maximum_instance_count = 4
  instance_memory_in_mb  = 2048

  # No VNet integration: storage, Key Vault and Dependency-Track are all
  # reached on their public endpoints, with Entra ID or an API key. The CD
  # job deploys through the public endpoint (Entra auth, basic publishing
  # credentials off). The app has no HTTP triggers.
  public_network_access_enabled                  = true
  webdeploy_publish_basic_authentication_enabled = false
  https_only                                     = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.collector.id]
  }

  app_settings = local.collector_app_settings

  site_config {
    application_insights_connection_string = azurerm_application_insights.collector.connection_string
  }

  # The provider hides AzureWebJobsStorage when it reads settings back, so the
  # empty value above would show as a change on every plan. Created with it anyway.
  lifecycle {
    ignore_changes = [app_settings["AzureWebJobsStorage"]]
  }

  depends_on = [azurerm_role_assignment.collector]
}
