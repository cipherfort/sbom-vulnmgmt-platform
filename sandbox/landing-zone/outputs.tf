output "jump_vm" {
  value = {
    name           = azurerm_linux_virtual_machine.jump.name
    resource_group = azurerm_resource_group.lz.name
    principal_id   = azurerm_linux_virtual_machine.jump.identity[0].principal_id
  }
}

output "nat_public_ip" {
  description = "Outbound IP of the Function, Dependency-Track and the jump VM."
  value       = azurerm_public_ip.nat.ip_address
}

# The landing-zone part of the platform's tfvars (runbook step 9).
output "platform_tfvars" {
  value = {
    environment                = local.env
    vnet_id                    = azurerm_virtual_network.this.id
    function_subnet_id         = azurerm_subnet.this["func"].id
    container_apps_subnet_id   = azurerm_subnet.this["cae"].id
    private_endpoint_subnet_id = azurerm_subnet.this["pe"].id
    private_dns_zone_ids       = { for k, z in azurerm_private_dns_zone.this : k => z.id }
    cps_workspace_id           = azurerm_log_analytics_workspace.this.id
  }
}
