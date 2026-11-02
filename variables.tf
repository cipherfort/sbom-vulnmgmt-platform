variable "environment" {
  description = "Short environment name used in resource names (rg-sbom-<env>, func-sbom-<env>, ...)"
  type        = string
  default     = "prd"
}

variable "global_name_suffix" {
  description = "Appended to globally unique names (Key Vault, storage accounts, Postgres) if the design-doc names are taken. Lowercase letters and digits only."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[a-z0-9]{0,6}$", var.global_name_suffix))
    error_message = "Lowercase letters and digits only, at most 6 characters."
  }
}

# ---------- Landing zone (confirmed in Phase 0) ----------

variable "vnet_id" {
  description = "Landing-zone VNet the platform's subnets live in. The Container Apps private DNS zone is linked to it."
  type        = string
}

variable "function_subnet_id" {
  description = "Subnet for Function App VNet integration. Must be delegated to Microsoft.App/environments (Flex Consumption requirement)."
  type        = string
}

variable "container_apps_subnet_id" {
  description = "Infrastructure subnet for the internal Container Apps environment (/27 or larger, delegated to Microsoft.App/environments)."
  type        = string
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for private endpoints (Key Vault, Storage, PostgreSQL)."
  type        = string
}

variable "private_dns_zone_ids" {
  description = "Landing-zone private DNS zone IDs, keyed by: vault, blob, queue, table, file, postgres."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["vault", "blob", "queue", "table", "file", "postgres"] : contains(keys(var.private_dns_zone_ids), k)])
    error_message = "private_dns_zone_ids needs keys: vault, blob, queue, table, file, postgres."
  }
}

variable "deployer_ip_ranges" {
  description = "Public egress CIDRs of whatever runs terraform apply (the cps-ubuntu-latest-private runner), allowed through the Key Vault firewall so Terraform can write the Postgres password. Leave empty if the runner reaches the vault over the private endpoint."
  type        = list(string)
  default     = []
}

# ---------- CPS Sentinel / Log Analytics workspace ----------

variable "cps_workspace_id" {
  description = "Resource ID of the existing CPS Log Analytics workspace that has Sentinel on. Receives the SBOM tables and all diagnostic logs."
  type        = string
}

# ---------- GitHub ----------

variable "github_enterprise_slug" {
  description = "GitHub Enterprise Cloud slug"
  type        = string
}

variable "github_app_id" {
  description = "App ID of cps-sbom-collector"
  type        = string
}

variable "github_installer_app_id" {
  description = "App ID of cps-app-installer (Phase 2). Empty disables the weekly installer function."
  type        = string
  default     = ""
}

variable "github_installer_installation_id" {
  description = "Enterprise installation ID of cps-app-installer (Phase 2)"
  type        = string
  default     = ""
}

# ---------- Dependency-Track ----------

variable "dtrack_image_tag" {
  description = "Dependency-Track image tag (apiserver + frontend share the same release train). Collection projects (the per-org parents) need 4.13.0 or later — not 4.12 as the design doc says."
  type        = string
  default     = "4.14.6"
}

variable "dtrack_oidc_client_id" {
  description = "Client ID of the Dependency-Track Entra app registration. Empty disables OIDC sign-in. Ignored when manage_entra is true (the app is created here)."
  type        = string
  default     = ""
}

# ---------- Phase 2: Entra ----------

variable "manage_entra" {
  description = "Create the Entra groups and the Dependency-Track app registration with Terraform. Needs Graph permissions (Group.ReadWrite.All, Application.ReadWrite.OwnedBy, AppRoleAssignment.ReadWrite.All, Application.Read.All) on the deploying identity; leave false to do it by hand (deployment runbook step 19)."
  type        = bool
  default     = false
}

variable "sbom_orgs" {
  description = "GitHub orgs in scope. One sg-sbom-org-<org> Entra group each (when manage_entra is true)."
  type        = list(string)
  default     = []
}

# ---------- Phase 2: Sentinel content ----------

variable "banned_packages" {
  description = "Seed rows for the BannedPackages watchlist. PackageName is matched against GitHubSbom_CL.PackageName; Reason is free text."
  type = list(object({
    PackageName = string
    Reason      = string
  }))
  default = []
}

# ---------- Alerting ----------

variable "alert_email" {
  description = "Mailbox for collector failure alerts (N5)"
  type        = string
}
