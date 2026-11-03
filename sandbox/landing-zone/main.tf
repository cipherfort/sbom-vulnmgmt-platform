# Stand-in for the pieces a real landing zone provides (runbook step 3), so the
# platform can be deployed into a test subscription that has no landing zone.
# Not for production: the team's landing zone owns these there.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.60"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-security-platform"
    storage_account_name = "stsecplatstate001"
    container_name       = "terraform-state"
    key                  = "sandbox-landing-zone.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  storage_use_azuread = true
  features {}
}

variable "environment" {
  description = "Must match the platform's var.environment."
  type        = string
  default     = "tst"
}

variable "location" {
  type    = string
  default = "uksouth"
}

variable "address_space" {
  type    = string
  default = "10.10.0.0/24"
}

locals {
  env = var.environment
  tags = {
    environment = local.env
    managed_by  = "terraform"
    purpose     = "sbom-platform-sandbox-landing-zone"
  }

  # /24 split: Container Apps /25, Function /27, private endpoints /27, management /26.
  subnets = {
    cae  = { prefix = cidrsubnet(var.address_space, 1, 0), delegate = true, nat = true }
    func = { prefix = cidrsubnet(var.address_space, 3, 4), delegate = true, nat = true }
    pe   = { prefix = cidrsubnet(var.address_space, 3, 5), delegate = false, nat = false }
    mgmt = { prefix = cidrsubnet(var.address_space, 2, 3), delegate = false, nat = true }
  }

  dns_zones = {
    vault    = "privatelink.vaultcore.azure.net"
    blob     = "privatelink.blob.core.windows.net"
    queue    = "privatelink.queue.core.windows.net"
    table    = "privatelink.table.core.windows.net"
    file     = "privatelink.file.core.windows.net"
    postgres = "privatelink.postgres.database.azure.com"
  }
}

resource "azurerm_resource_group" "lz" {
  name     = "rg-sbom-lz-${local.env}"
  location = var.location
  tags     = local.tags
}

# The platform looks this up as a data source (main.tf), so it must exist first.
resource "azurerm_resource_group" "platform" {
  name     = "rg-sbom-${local.env}"
  location = var.location
  tags     = local.tags
}

# ---------- Network ----------

resource "azurerm_virtual_network" "this" {
  name                = "vnet-sbom-${local.env}"
  resource_group_name = azurerm_resource_group.lz.name
  location            = azurerm_resource_group.lz.location
  address_space       = [var.address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "this" {
  for_each = local.subnets

  name                            = "snet-sbom-${each.key}"
  resource_group_name             = azurerm_resource_group.lz.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [each.value.prefix]
  default_outbound_access_enabled = false

  dynamic "delegation" {
    for_each = each.value.delegate ? [1] : []
    content {
      name = "aca"
      service_delegation {
        name    = "Microsoft.App/environments"
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}

# Outbound internet for the Function, Dependency-Track (image pulls, vulnerability
# feeds) and the jump VM. A real landing zone routes this through its hub firewall.
resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-sbom-${local.env}"
  resource_group_name = azurerm_resource_group.lz.name
  location            = azurerm_resource_group.lz.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "this" {
  name                = "ng-sbom-${local.env}"
  resource_group_name = azurerm_resource_group.lz.name
  location            = azurerm_resource_group.lz.location
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "this" {
  for_each = { for k, v in local.subnets : k => v if v.nat }

  subnet_id      = azurerm_subnet.this[each.key].id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ---------- Private DNS ----------

resource "azurerm_private_dns_zone" "this" {
  for_each = local.dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.lz.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.dns_zones

  name                  = "link-${azurerm_virtual_network.this.name}"
  resource_group_name   = azurerm_resource_group.lz.name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this.id
  tags                  = local.tags
}

# ---------- Stand-in for the CPS Sentinel workspace ----------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-sbom-${local.env}"
  resource_group_name = azurerm_resource_group.lz.name
  location            = azurerm_resource_group.lz.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "this" {
  workspace_id = azurerm_log_analytics_workspace.this.id
}

# ---------- Jump VM (the admin workstation) ----------
# No public IP. Reach it with `az vm run-command invoke`, or Bastion if added.

resource "tls_private_key" "jump" {
  algorithm = "ED25519"
}

resource "azurerm_network_interface" "jump" {
  name                = "nic-vm-sbom-jump-${local.env}"
  resource_group_name = azurerm_resource_group.lz.name
  location            = azurerm_resource_group.lz.location
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.this["mgmt"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "jump" {
  name                  = "vm-sbom-jump-${local.env}"
  resource_group_name   = azurerm_resource_group.lz.name
  location              = azurerm_resource_group.lz.location
  size                  = "Standard_B2s"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.jump.id]
  tags                  = local.tags

  # Signs in as the admin for dtrack_admin.py (runbook step 14), which writes
  # API keys to Key Vault. Grant it Key Vault Secrets Officer on the platform's vault.
  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.jump.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOT
    #cloud-config
    package_update: true
    packages: [python3-venv, python3-pip, jq, curl, unzip, git, dnsutils]
  EOT
  )

  depends_on = [azurerm_subnet_nat_gateway_association.this]
}
