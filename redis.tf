# DefectDojo's Celery broker/result backend. Not needed by Dependency-Track.
# Classic azurerm_redis_cache (Basic/Standard/Premium) is retired for new
# resources on this subscription/region — Azure requires Azure Managed Redis.
resource "azurerm_managed_redis" "defectdojo" {
  name                = "redis-${var.name_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  sku_name = "Balanced_B0"

  default_database {
    access_keys_authentication_enabled = true

    # Default OSSCluster policy returns MOVED redirects to shard IPs the
    # client must connect to directly — Celery's redis broker (kombu) isn't
    # cluster-aware and can't follow those. EnterpriseCluster proxies
    # everything through the single endpoint instead.
    clustering_policy = "NoCluster"
  }
}

resource "azurerm_key_vault_secret" "redis_primary_key" {
  name         = "redis-primary-key"
  value        = azurerm_managed_redis.defectdojo.default_database[0].primary_access_key
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin]
}
