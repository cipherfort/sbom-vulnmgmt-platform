locals {
  dtrack_db_url = "jdbc:postgresql://${azurerm_postgresql_flexible_server.this.fqdn}:5432/dtrack"
}

# User-assigned identity (rather than SystemAssigned) so the Key Vault role
# assignment can be created — and take effect — before the container app
# that needs it, avoiding a create-time chicken/egg on the secret reference.
resource "azurerm_user_assigned_identity" "dtrack" {
  name                = "id-dtrack"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
}

resource "azurerm_role_assignment" "dtrack_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.dtrack.principal_id
}

resource "azurerm_container_app" "dtrack_apiserver" {
  name                         = "ca-dtrack-api"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.dtrack.id]
  }

  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.postgres_admin_password.id
    identity            = azurerm_user_assigned_identity.dtrack.id
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "dtrack-apiserver"
      image  = "dependencytrack/apiserver:${var.dtrack_image_tag}"
      cpu    = 2.0
      memory = "4Gi"

      # Apiserver refuses to start below 4GB heap (RequirementsVerifier) —
      # default container-aware JVM sizing won't get there on its own, so
      # this must be explicit. Leaves no headroom above the 4Gi container
      # limit, which is the max a single container gets in a Consumption-only
      # Container Apps environment; revisit with a Dedicated workload profile
      # if this needs to hold real scan workloads instead of just a smoke test.
      env {
        name  = "EXTRA_JAVA_OPTIONS"
        value = "-Xmx4g"
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
        value = azurerm_postgresql_flexible_server.this.administrator_login
      }
      env {
        name        = "ALPINE_DATABASE_PASSWORD"
        secret_name = "db-password"
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

  depends_on = [azurerm_role_assignment.dtrack_kv_secrets_user]
}

# Frontend is a separate, stateless SPA — no DB access, no Key Vault secrets.
resource "azurerm_container_app" "dtrack_frontend" {
  name                         = "ca-dtrack-frontend"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"

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
        value = "https://${azurerm_container_app.dtrack_apiserver.ingress[0].fqdn}"
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
