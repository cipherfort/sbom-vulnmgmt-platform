variable "location" {
  description = "Azure region for the security platform"
  type        = string
  default     = "uksouth"
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
