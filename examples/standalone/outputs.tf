output "dependency_track_url" {
  description = "Dependency-Track frontend URL — set as the DEPENDENCY_TRACK_URL repo variable on consuming repos (point at the apiserver's URL, not the frontend's, for the API base)"
  value       = module.platform.dependency_track_url
}

output "dependency_track_api_url" {
  description = "Dependency-Track API server URL — this is what CI actually calls"
  value       = module.platform.dependency_track_api_url
}

output "defectdojo_url" {
  description = "DefectDojo URL — set as the DEFECTDOJO_URL repo variable on consuming repos"
  value       = module.platform.defectdojo_url
}

output "key_vault_name" {
  description = "Key Vault holding generated admin/DB credentials"
  value       = module.platform.key_vault_name
}
