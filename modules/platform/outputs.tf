output "dependency_track_url" {
  description = "Dependency-Track frontend URL — set as the DEPENDENCY_TRACK_URL repo variable on consuming repos (point at the apiserver's URL, not the frontend's, for the API base)"
  value       = "https://${azurerm_container_app.dtrack_frontend.ingress[0].fqdn}"
}

output "dependency_track_api_url" {
  description = "Dependency-Track API server URL — this is what CI actually calls"
  value       = "https://${azurerm_container_app.dtrack_apiserver.ingress[0].fqdn}"
}

output "defectdojo_url" {
  description = "DefectDojo URL — set as the DEFECTDOJO_URL repo variable on consuming repos"
  value       = "https://${azurerm_container_app.defectdojo_web.ingress[0].fqdn}"
}

output "key_vault_name" {
  description = "Key Vault holding generated admin/DB credentials"
  value       = azurerm_key_vault.this.name
}
