module "platform" {
  source = "../../modules/platform"

  location                  = var.location
  name_prefix               = var.name_prefix
  allowed_ip_ranges         = var.allowed_ip_ranges
  dtrack_image_tag          = var.dtrack_image_tag
  defectdojo_image_tag      = var.defectdojo_image_tag
  admin_email               = var.admin_email
  enable_private_networking = var.enable_private_networking
  high_availability_enabled = var.high_availability_enabled
}
