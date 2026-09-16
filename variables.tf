variable "location" {
  description = "Azure region for the security platform"
  type        = string
  default     = "uksouth"
}

variable "name_prefix" {
  description = <<-EOT
    Short identifier prepended to every resource name, so multiple
    deployments can coexist in one subscription/tenant without collisions.
    No default — every deployer chooses one explicitly. Capped at 12
    characters: Key Vault names are capped at 24 total, and this platform's
    pattern is "kv-<name_prefix>-<6-char random suffix>" (10 fixed chars,
    leaving 14 in theory; capped at 12 here for a safety margin).
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,10}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 2-12 characters, lowercase letters/digits/hyphens only, start with a letter, and end with a letter or digit."
  }

  validation {
    condition     = !can(regex("--", var.name_prefix))
    error_message = "name_prefix must not contain consecutive hyphens."
  }
}

variable "allowed_ip_ranges" {
  description = "CIDR ranges allowed to reach the Dependency-Track and DefectDojo web UIs/APIs — typically your office/VPN egress ranges"
  type        = list(string)
}

variable "dtrack_image_tag" {
  description = "Dependency-Track image tag (apiserver + frontend share the same release train)"
  type        = string
  default     = "4.12.4"
}

variable "defectdojo_image_tag" {
  description = "DefectDojo image tag (django, nginx, celery images share the same release train)"
  type        = string
  default     = "2.42.1"
}

variable "admin_email" {
  description = "Email address configured as DefectDojo's admin account email (DD_ADMIN_MAIL)"
  type        = string
  default     = "admin@example.com"
}
