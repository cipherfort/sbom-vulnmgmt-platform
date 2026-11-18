locals {
  dtrack_db_url = "jdbc:postgresql://${azurerm_postgresql_flexible_server.dtrack.fqdn}:5432/${azurerm_postgresql_flexible_server_database.dtrack.name}?sslmode=require"

  dtrack_oidc_client_id = var.manage_entra ? azuread_application.dtrack[0].client_id : var.dtrack_oidc_client_id
  dtrack_oidc_issuer    = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"

  # Entra sign-in, once there is an app registration.
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

# Workload profiles, so the API container can have 4 vCPU / 8 GiB.
resource "azurerm_container_app_environment" "this" {
  name                       = "cae-sbom-${local.env}"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = data.azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app_environment_storage" "dtrack_data" {
  name                         = "dtrackdata"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.dtrack.name
  share_name                   = azurerm_storage_share.dtrack_data.name
  access_key                   = azurerm_storage_account.dtrack.primary_access_key
  access_mode                  = "ReadWrite"
}

# User-assigned, so its Key Vault role exists before the app first starts.
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
    # The API server keeps local state, so it must not scale out.
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

      # Leaves headroom under the 8 GiB container limit.
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

  # Not IP-restricted: the collector has no fixed outbound IP, and browsers
  # call it from the UI. Every call except /api/version needs a key or a session.
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

    dynamic "ip_security_restriction" {
      for_each = var.allowed_ip_ranges
      content {
        name             = "allow-${ip_security_restriction.key}"
        action           = "Allow"
        ip_address_range = ip_security_restriction.value
      }
    }

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}
