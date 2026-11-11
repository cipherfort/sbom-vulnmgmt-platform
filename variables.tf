variable "environment" {
  description = "Short environment name used in resource names (rg-sbom-<env>, func-sbom-<env>, ...)"
  type        = string
  default     = "prd"
}

variable "global_name_suffix" {
  description = "Appended to globally unique names (Key Vault, storage accounts, Postgres) if the default names are taken. Lowercase letters and digits only."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[a-z0-9]{0,6}$", var.global_name_suffix))
    error_message = "Lowercase letters and digits only, at most 6 characters."
  }
}

# ---------- Network ----------

variable "allowed_ip_ranges" {
  description = "CIDRs allowed to open the Dependency-Track UI (office, VPN egress). Empty allows everyone. The API stays open to the internet because the collector has no fixed outbound IP; every API call needs a key or a signed-in session."
  type        = list(string)
  default     = []
}

# ---------- GitHub ----------

variable "github_app_id" {
  description = "App ID of cps-sbom-collector, the org-owned GitHub App the collector signs in as"
  type        = string
}

# ---------- Dependency-Track ----------

variable "dtrack_image_tag" {
  description = "Dependency-Track image tag (apiserver + frontend share the same release train). The org parent collection project needs 4.13.0 or later."
  type        = string
  default     = "4.14.6"
}

variable "dtrack_oidc_client_id" {
  description = "Client ID of the Dependency-Track Entra app registration. Empty disables OIDC sign-in. Ignored when manage_entra is true (the app is created here)."
  type        = string
  default     = ""
}

# ---------- Entra (optional) ----------

variable "manage_entra" {
  description = "Create the Entra groups and the Dependency-Track app registration with Terraform. Needs Graph permissions (Group.ReadWrite.All, Application.ReadWrite.OwnedBy, AppRoleAssignment.ReadWrite.All, Application.Read.All) on the deploying identity; leave false to do it by hand (deployment runbook step 17)."
  type        = bool
  default     = false
}

# ---------- Alerting ----------

variable "alert_email" {
  description = "Mailbox for collector failure alerts"
  type        = string
}
