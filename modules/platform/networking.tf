resource "azurerm_virtual_network" "this" {
  count               = var.enable_private_networking ? 1 : 0
  name                = "vnet-${var.name_prefix}"
  address_space       = ["10.100.0.0/16"]
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
}

# CAE infrastructure subnet, /23 minimum. Delegated to Microsoft.App/
# environments — confirmed empirically against the live Azure API (a
# prior version of this file left it undelegated based on Microsoft Learn
# text describing Consumption-only environments as needing no delegation;
# the actual CreateOrUpdate call rejects an undelegated subnet with
# "ManagedEnvironmentSubnetDelegationError: The subnet of the environment
# must be delegated to the service 'Microsoft.App/environments'" whenever
# infrastructure_subnet_id is set, regardless of workload-profile status).
# This subnet exists only to give the environment network line-of-sight to
# the private-endpointed Key Vault and delegated-subnet Postgres below —
# ingress stays External (internal_load_balancer_enabled is never set
# anywhere in this repo), so GitHub-hosted CI runners keep reaching the
# platform unchanged.
resource "azurerm_subnet" "cae" {
  count                = var.enable_private_networking ? 1 : 0
  name                 = "snet-${var.name_prefix}-cae"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = ["10.100.0.0/23"]

  delegation {
    name = "cae-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  count                = var.enable_private_networking ? 1 : 0
  name                 = "snet-${var.name_prefix}-postgres"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = ["10.100.2.0/28"] # /28 minimum for a delegated Postgres subnet

  delegation {
    name = "postgres-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  count                             = var.enable_private_networking ? 1 : 0
  name                              = "snet-${var.name_prefix}-pe"
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.this[0].name
  address_prefixes                  = ["10.100.2.16/28"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_private_dns_zone" "postgres" {
  count               = var.enable_private_networking ? 1 : 0
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  count                 = var.enable_private_networking ? 1 : 0
  name                  = "postgres-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres[0].name
  virtual_network_id    = azurerm_virtual_network.this[0].id
}

resource "azurerm_private_dns_zone" "keyvault" {
  count               = var.enable_private_networking ? 1 : 0
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault" {
  count                 = var.enable_private_networking ? 1 : 0
  name                  = "keyvault-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault[0].name
  virtual_network_id    = azurerm_virtual_network.this[0].id
}

resource "azurerm_private_endpoint" "keyvault" {
  count               = var.enable_private_networking ? 1 : 0
  name                = "pe-kv-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = azurerm_subnet.private_endpoints[0].id

  private_service_connection {
    name                           = "kv-connection"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.keyvault[0].id]
  }
}
