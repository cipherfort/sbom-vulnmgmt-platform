locals {
  defectdojo_redis_url = "rediss://:${azurerm_managed_redis.defectdojo.default_database[0].primary_access_key}@${azurerm_managed_redis.defectdojo.hostname}:${azurerm_managed_redis.defectdojo.default_database[0].port}/0"

  # Shared env vars across the django/uwsgi, celeryworker, and celerybeat
  # containers — all three need DB + broker + crypto material.
  defectdojo_common_env = {
    DD_DATABASE_ENGINE      = "django.db.backends.postgresql"
    DD_DATABASE_HOST        = azurerm_postgresql_flexible_server.this.fqdn
    DD_DATABASE_PORT        = "5432"
    DD_DATABASE_NAME        = azurerm_postgresql_flexible_server_database.defectdojo.name
    DD_DATABASE_USER        = azurerm_postgresql_flexible_server.this.administrator_login
    DD_DATABASE_SSL_REQUIRE = "true"
    DD_CELERY_BROKER_URL    = local.defectdojo_redis_url
  }
}

resource "azurerm_user_assigned_identity" "defectdojo" {
  name                = "id-${var.name_prefix}-defectdojo"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
}

resource "azurerm_role_assignment" "defectdojo_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.defectdojo.principal_id
}

# django/uwsgi + nginx as two containers in one Container App revision —
# mirrors the upstream docker-compose topology. Containers in the same
# revision share a network namespace, so nginx reaches uwsgi via localhost.
#
# Static files (CSS/JS) need no volume — the nginx image bakes them in at
# build time (Dockerfile.nginx-debian: `collectstatic` into
# /usr/share/nginx/html/static during the image build, no runtime step).
# A prior version of this file mounted an EmptyDir there, which shadowed
# those baked-in files with an empty directory and served an unstyled page.
#
# Media (user-uploaded files) has no shared volume yet — uploads currently
# land on uwsgi's ephemeral filesystem only and nginx can't serve them.
# Fine for this smoke test; needs a real shared volume before this holds
# actual DefectDojo usage with file uploads.
resource "azurerm_container_app" "defectdojo_web" {
  name                         = "ca-${var.name_prefix}-dd-web"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  workload_profile_name        = var.enable_private_networking ? "Consumption" : null

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.defectdojo.id]
  }

  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.postgres_admin_password.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }
  secret {
    name                = "secret-key"
    key_vault_secret_id = azurerm_key_vault_secret.defectdojo_secret_key.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }
  secret {
    name                = "credential-aes-key"
    key_vault_secret_id = azurerm_key_vault_secret.defectdojo_credential_aes_key.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }
  secret {
    name                = "admin-password"
    key_vault_secret_id = azurerm_key_vault_secret.defectdojo_admin_password.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }

  template {
    min_replicas = var.high_availability_enabled ? 2 : 1
    max_replicas = var.high_availability_enabled ? 2 : 1

    # Upstream docker-compose runs this as a separate one-shot "initializer"
    # service (same image, different entrypoint) that runs Django migrations
    # and creates the admin user before uwsgi/nginx start — DD_INITIALIZE has
    # no effect on entrypoint-uwsgi.sh itself. init_container runs to
    # completion before the main containers start, in the same replica.
    init_container {
      name    = "initializer"
      image   = "defectdojo/defectdojo-django:${var.defectdojo_image_tag}"
      cpu     = 0.5
      memory  = "1Gi"
      command = ["/entrypoint-initializer.sh"]

      dynamic "env" {
        for_each = local.defectdojo_common_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "DD_DATABASE_PASSWORD"
        secret_name = "db-password"
      }
      env {
        name        = "DD_SECRET_KEY"
        secret_name = "secret-key"
      }
      env {
        name        = "DD_CREDENTIAL_AES_256_KEY"
        secret_name = "credential-aes-key"
      }
      env {
        name  = "DD_INITIALIZE"
        value = "true"
      }
      env {
        name  = "DD_ADMIN_USER"
        value = "admin"
      }
      env {
        name        = "DD_ADMIN_PASSWORD"
        secret_name = "admin-password"
      }
      env {
        name  = "DD_ADMIN_MAIL"
        value = var.admin_email
      }
    }

    container {
      name   = "uwsgi"
      image  = "defectdojo/defectdojo-django:${var.defectdojo_image_tag}"
      cpu    = 1.0
      memory = "2Gi"

      dynamic "env" {
        for_each = local.defectdojo_common_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "DD_DATABASE_PASSWORD"
        secret_name = "db-password"
      }
      env {
        name        = "DD_SECRET_KEY"
        secret_name = "secret-key"
      }
      env {
        name        = "DD_CREDENTIAL_AES_256_KEY"
        secret_name = "credential-aes-key"
      }
      env {
        name  = "DD_ALLOWED_HOSTS"
        value = "*"
      }
      env {
        name  = "DD_INITIALIZE"
        value = "true"
      }
      env {
        name  = "DD_ADMIN_USER"
        value = "admin"
      }
      env {
        name        = "DD_ADMIN_PASSWORD"
        secret_name = "admin-password"
      }
      env {
        name  = "DD_ADMIN_MAIL"
        value = var.admin_email
      }
    }

    container {
      name   = "nginx"
      image  = "defectdojo/defectdojo-nginx:${var.defectdojo_image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "DD_UWSGI_HOST"
        value = "127.0.0.1"
      }
      env {
        name  = "DD_UWSGI_PORT"
        value = "3031"
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

  depends_on = [azurerm_role_assignment.defectdojo_kv_secrets_user]
}

resource "azurerm_container_app" "defectdojo_celeryworker" {
  name                         = "ca-${var.name_prefix}-dd-worker"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  workload_profile_name        = var.enable_private_networking ? "Consumption" : null

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.defectdojo.id]
  }

  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.postgres_admin_password.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }
  secret {
    name                = "secret-key"
    key_vault_secret_id = azurerm_key_vault_secret.defectdojo_secret_key.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }
  secret {
    name                = "credential-aes-key"
    key_vault_secret_id = azurerm_key_vault_secret.defectdojo_credential_aes_key.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }

  template {
    min_replicas = var.high_availability_enabled ? 2 : 1
    max_replicas = var.high_availability_enabled ? 2 : 1

    container {
      name    = "celeryworker"
      image   = "defectdojo/defectdojo-django:${var.defectdojo_image_tag}"
      cpu     = 0.5
      memory  = "1Gi"
      command = ["/entrypoint-celery-worker.sh"]

      dynamic "env" {
        for_each = local.defectdojo_common_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "DD_DATABASE_PASSWORD"
        secret_name = "db-password"
      }
      env {
        name        = "DD_SECRET_KEY"
        secret_name = "secret-key"
      }
      env {
        name        = "DD_CREDENTIAL_AES_256_KEY"
        secret_name = "credential-aes-key"
      }
    }
  }

  depends_on = [azurerm_role_assignment.defectdojo_kv_secrets_user]
}

resource "azurerm_container_app" "defectdojo_celerybeat" {
  name                         = "ca-${var.name_prefix}-dd-beat"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  workload_profile_name        = var.enable_private_networking ? "Consumption" : null

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.defectdojo.id]
  }

  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.postgres_admin_password.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }
  secret {
    name                = "secret-key"
    key_vault_secret_id = azurerm_key_vault_secret.defectdojo_secret_key.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }
  secret {
    name                = "credential-aes-key"
    key_vault_secret_id = azurerm_key_vault_secret.defectdojo_credential_aes_key.id
    identity            = azurerm_user_assigned_identity.defectdojo.id
  }

  template {
    min_replicas = var.high_availability_enabled ? 2 : 1
    max_replicas = var.high_availability_enabled ? 2 : 1

    container {
      name    = "celerybeat"
      image   = "defectdojo/defectdojo-django:${var.defectdojo_image_tag}"
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["/entrypoint-celery-beat.sh"]

      dynamic "env" {
        for_each = local.defectdojo_common_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "DD_DATABASE_PASSWORD"
        secret_name = "db-password"
      }
      env {
        name        = "DD_SECRET_KEY"
        secret_name = "secret-key"
      }
      env {
        name        = "DD_CREDENTIAL_AES_256_KEY"
        secret_name = "credential-aes-key"
      }
    }
  }

  depends_on = [azurerm_role_assignment.defectdojo_kv_secrets_user]
}
