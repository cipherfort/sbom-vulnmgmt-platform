locals {
  dtrack_db_url = "jdbc:postgresql://${azurerm_postgresql_flexible_server.dtrack.fqdn}:5432/${azurerm_postgresql_flexible_server_database.dtrack.name}?sslmode=require"

  dtrack_oidc_client_id = var.manage_entra ? azuread_application.dtrack[0].client_id : var.dtrack_oidc_client_id
  dtrack_oidc_issuer    = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"

  # Only set once there is an Entra app to sign in with — until then the
  # local admin account is the only way in (first-login step, README).
  dtrack_api_oidc_env = local.dtrack_oidc_client_id == "" ? {} : {
    ALPINE_OIDC_ENABLED              = "true"
    ALPINE_OIDC_ISSUER               = local.dtrack_oidc_issuer
    ALPINE_OIDC_CLIENT_ID            = local.dtrack_oidc_client_id
    ALPINE_OIDC_USERNAME_CLAIM       = "preferred_username"
    ALPINE_OIDC_TEAMS_CLAIM          = "groups"
    ALPINE_OIDC_USER_PROVISIONING    = "true"
    ALPINE_OIDC_TEAM_SYNCHRONIZATION = "true"
  }

  dtrack_ui_oidc_env = local.dtrack_oidc_client_id == "" ? {} : {
    OIDC_ISSUER    = local.dtrack_oidc_issuer
    OIDC_CLIENT_ID = local.dtrack_oidc_client_id
  }
}

# Internal-only environment on the landing-zone subnet. Workload profiles
# (rather than the legacy Consumption-only mode) are what allow a single
# container to have 4 vCPU / 8 GiB on the Consumption profile — the old
# Consumption-only environment capped containers at 2 vCPU / 4 GiB.
resource "azurerm_container_app_environment" "this" {
  name                           = "cae-sbom-${local.env}"
  resource_group_name            = data.azurerm_resource_group.this.name
  location                       = data.azurerm_resource_group.this.location
  infrastructure_subnet_id       = var.container_apps_subnet_id
  internal_load_balancer_enabled = true
  log_analytics_workspace_id     = var.cps_workspace_id
  tags                           = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# Internal environments get a private VIP but no DNS. The Function App
# reaches Dependency-Track through this zone; people on the corporate
# network reach it once the landing zone's DNS forwards this domain here.
resource "azurerm_private_dns_zone" "cae" {
  name                = azurerm_container_app_environment.this.default_domain
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "cae_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.cae.name
  resource_group_name = data.azurerm_resource_group.this.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
}

resource "azurerm_private_dns_zone_virtual_network_link" "cae" {
  name                  = "cae-sbom-${local.env}"
  resource_group_name   = data.azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.cae.name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_container_app_environment_storage" "dtrack_data" {
  name                         = "dtrackdata"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.dtrack.name
  share_name                   = azurerm_storage_share.dtrack_data.name
  access_key                   = azurerm_storage_account.dtrack.primary_access_key
  access_mode                  = "ReadWrite"
}

# User-assigned (not system-assigned as the design doc says) so the Key
# Vault role exists before the app is created — a system-assigned identity
# can't be granted access until the app exists, and the app can't start
# without the secret.
resource "azurerm_user_assigned_identity" "dtrack" {
  name                = "id-dtrack-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "dtrack_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.dtrack.principal_id
}

resource "azurerm_container_app" "dtrack_api" {
  name                         = "ca-dtrack-api"
  resource_group_name          = data.azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.dtrack.id]
  }

  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.postgres_admin_password.versionless_id
    identity            = azurerm_user_assigned_identity.dtrack.id
  }

  template {
    # Exactly one replica: the API server keeps search indexes and its
    # task queue on local state, so it must not scale out.
    min_replicas = 1
    max_replicas = 1

    volume {
      name         = "dtrack-data"
      storage_name = azurerm_container_app_environment_storage.dtrack_data.name
      storage_type = "AzureFile"
    }

    container {
      name   = "dtrack-apiserver"
      image  = "dependencytrack/apiserver:${var.dtrack_image_tag}"
      cpu    = 4.0
      memory = "8Gi"

      volume_mounts {
        name = "dtrack-data"
        path = "/data"
      }

      # Heap below the 8 GiB container limit, leaving room for metaspace,
      # threads and Lucene's off-heap buffers.
      env {
        name  = "EXTRA_JAVA_OPTIONS"
        value = "-Xmx6g"
      }
      env {
        name  = "ALPINE_DATABASE_MODE"
        value = "external"
      }
      env {
        name  = "ALPINE_DATABASE_URL"
        value = local.dtrack_db_url
      }
      env {
        name  = "ALPINE_DATABASE_DRIVER"
        value = "org.postgresql.Driver"
      }
      env {
        name  = "ALPINE_DATABASE_USERNAME"
        value = azurerm_postgresql_flexible_server.dtrack.administrator_login
      }
      env {
        name        = "ALPINE_DATABASE_PASSWORD"
        secret_name = "db-password"
      }

      dynamic "env" {
        for_each = local.dtrack_api_oidc_env
        content {
          name  = env.key
          value = env.value
        }
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/api/version"
        initial_delay           = 60
        interval_seconds        = 30
        failure_count_threshold = 10
      }
    }
  }

  # In an internal environment, "external" means reachable from the VNet
  # (and peered networks) — the Function App needs that. Nothing here is on
  # the internet.
  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  depends_on = [azurerm_role_assignment.dtrack_kv_secrets_user]
}

# Stateless SPA — no DB, no secrets.
resource "azurerm_container_app" "dtrack_ui" {
  name                         = "ca-dtrack-ui"
  resource_group_name          = data.azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "dtrack-frontend"
      image  = "dependencytrack/frontend:${var.dtrack_image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "API_BASE_URL"
        value = "https://${azurerm_container_app.dtrack_api.ingress[0].fqdn}"
      }

      dynamic "env" {
        for_each = local.dtrack_ui_oidc_env
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}
