output "dependency_track_url" {
  description = "Dependency-Track frontend URL (internal; reachable from the landing-zone VNet and the corporate network once DNS forwards the environment domain)"
  value       = "https://${azurerm_container_app.dtrack_ui.ingress[0].fqdn}"
}

output "dependency_track_api_url" {
  description = "Dependency-Track API server URL — the DEPENDENCY_TRACK_URL variable for repos calling sbom-scan.yml, and what dtrack_admin.py talks to"
  value       = "https://${azurerm_container_app.dtrack_api.ingress[0].fqdn}"
}

output "container_apps_domain" {
  description = "Default domain of the internal Container Apps environment — the landing zone's DNS must forward this zone to reach Dependency-Track from the corporate network"
  value       = azurerm_container_app_environment.this.default_domain
}

output "container_apps_static_ip" {
  description = "Private IP the environment domain resolves to"
  value       = azurerm_container_app_environment.this.static_ip_address
}

output "function_app_name" {
  description = "Collector Function App — the FUNCTION_APP_NAME repo variable for cd.yml's collector-deploy job"
  value       = azurerm_function_app_flex_consumption.collector.name
}

output "key_vault_name" {
  description = "Key Vault for the GitHub App private keys and the Dependency-Track API key (added by hand)"
  value       = azurerm_key_vault.this.name
}

output "sbom_storage_account" {
  description = "Raw SBOM archive, work queue and state table"
  value       = azurerm_storage_account.sbom.name
}

output "dce_logs_ingestion_endpoint" {
  description = "Logs Ingestion endpoint (also set on the Function App as DCE_ENDPOINT)"
  value       = azurerm_monitor_data_collection_endpoint.sbom.logs_ingestion_endpoint
}

output "dcr_immutable_id" {
  description = "Data collection rule immutable ID (also set on the Function App as DCR_IMMUTABLE_ID)"
  value       = azurerm_monitor_data_collection_rule.sbom.immutable_id
}

output "dtrack_oidc_client_id" {
  description = "Client ID Dependency-Track signs in with (empty until an Entra app exists)"
  value       = local.dtrack_oidc_client_id
}
