output "dependency_track_url" {
  description = "Dependency-Track frontend URL (limited to var.allowed_ip_ranges when set)"
  value       = "https://${azurerm_container_app.dtrack_ui.ingress[0].fqdn}"
}

output "dependency_track_api_url" {
  description = "Dependency-Track API server URL — the DEPENDENCY_TRACK_URL variable for repos calling sbom-scan.yml, and what dtrack_admin.py talks to"
  value       = "https://${azurerm_container_app.dtrack_api.ingress[0].fqdn}"
}

output "function_app_name" {
  description = "Collector Function App — the FUNCTION_APP_NAME repo variable for cd.yml's collector-deploy job"
  value       = azurerm_function_app_flex_consumption.collector.name
}

output "key_vault_name" {
  description = "Key Vault for the GitHub App private key and the Dependency-Track API keys (added by hand or by ops/first_setup.py)"
  value       = azurerm_key_vault.this.name
}

output "sbom_storage_account" {
  description = "Raw SBOM archive, work queue and state table"
  value       = azurerm_storage_account.sbom.name
}

output "log_analytics_workspace" {
  description = "Workspace holding the collector's Application Insights data and the platform's logs"
  value       = azurerm_log_analytics_workspace.this.name
}

output "dtrack_oidc_client_id" {
  description = "Client ID Dependency-Track signs in with (empty until an Entra app exists)"
  value       = local.dtrack_oidc_client_id
}
