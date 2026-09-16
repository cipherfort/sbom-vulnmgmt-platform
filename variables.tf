variable "location" {
  description = "Azure region for the security platform"
  type        = string
  default     = "uksouth"
}

variable "allowed_ip_ranges" {
  description = "CIDR ranges allowed to reach Dependency-Track and DefectDojo ingress (office/VPN egress + the cps-ubuntu-latest-private runner's egress)"
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
