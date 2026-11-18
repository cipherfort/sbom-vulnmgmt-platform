variable "environment" {
  description = "Used in every resource name: rg-sbom-<env>, kv-sbom-<env>, ..."
  type        = string
  default     = "prd"
}

variable "global_name_suffix" {
  description = "Added to the globally unique names (Key Vault, storage, Postgres, Function) if the defaults are taken"
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[a-z0-9]{0,6}$", var.global_name_suffix))
    error_message = "Lowercase letters and digits only, at most 6 characters."
  }
}

variable "allowed_ip_ranges" {
  description = "CIDRs allowed to open the Dependency-Track UI. Empty allows everyone. The API is not restricted."
  type        = list(string)
  default     = []
}

variable "github_app_id" {
  description = "App ID of the collector GitHub App"
  type        = string
}

variable "dtrack_image_tag" {
  description = "Dependency-Track version (4.13.0 or later)"
  type        = string
  default     = "4.14.6"
}

variable "dtrack_oidc_client_id" {
  description = "Client ID of the Dependency-Track Entra app registration. Empty means local accounts only."
  type        = string
  default     = ""
}

variable "manage_entra" {
  description = "Create the Entra groups and app registration here. Needs Microsoft Graph permissions on the deployer."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Mailbox for collector alerts"
  type        = string
}
