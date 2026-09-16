resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${var.name_prefix}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  # VNet integration only, never paired with internal_load_balancer_enabled —
  # gives line-of-sight to the private Key Vault/Postgres below while ingress
  # stays External/public. See networking.tf's azurerm_subnet.cae comment.
  infrastructure_subnet_id = var.enable_private_networking ? azurerm_subnet.cae[0].id : null

  # A VNet-integrated environment is always workload-profile-enabled on the
  # current Container Apps platform version (confirmed empirically — Azure
  # auto-attaches a default "Consumption" profile the moment
  # infrastructure_subnet_id is set, even though this repo's Consumption-
  # only environment otherwise has no workload_profile block at all).
  # Declaring it explicitly here avoids perpetual plan drift against that
  # server-side default.
  dynamic "workload_profile" {
    for_each = var.enable_private_networking ? [1] : []
    content {
      name                  = "Consumption"
      workload_profile_type = "Consumption"
    }
  }
}
