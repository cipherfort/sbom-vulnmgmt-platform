output "dependency_track_url" {
  description = "Dependency-Track UI"
  value       = "https://${azurerm_container_app.dtrack_ui.ingress[0].fqdn}"
}

output "dependency_track_api_url" {
  description = "Dependency-Track API (the DEPENDENCY_TRACK_URL for sbom-scan.yml)"
  value       = "https://${azurerm_container_app.dtrack_api.ingress[0].fqdn}"
}

output "resource_group_name" {
  description = "Resource group"
  value       = data.azurerm_resource_group.this.name
}

output "function_app_name" {
  description = "Collector Function App"
  value       = azurerm_function_app_flex_consumption.collector.name
}

output "key_vault_name" {
  description = "Key Vault"
  value       = azurerm_key_vault.this.name
}

output "sbom_storage_account" {
  description = "Collector storage account"
  value       = azurerm_storage_account.sbom.name
}

output "log_analytics_workspace" {
  description = "Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.this.name
}

output "dtrack_oidc_client_id" {
  description = "Entra app client ID (empty without Entra)"
  value       = local.dtrack_oidc_client_id
}
