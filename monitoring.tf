resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-sbom-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 90
  tags                = local.tags
}

resource "azurerm_monitor_action_group" "sbom" {
  name                = "ag-sbom-${local.env}"
  resource_group_name = data.azurerm_resource_group.this.name
  short_name          = "sbom"
  tags                = local.tags

  email_receiver {
    name                    = "cps-platform"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# Azure has no per-queue length metric, so report_poison_depth logs it every 15 minutes.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "poison_queue" {
  name                 = "sbom-poison-queue-not-empty"
  resource_group_name  = data.azurerm_resource_group.this.name
  location             = data.azurerm_resource_group.this.location
  scopes               = [azurerm_application_insights.collector.id]
  description          = "Messages in sbom-work-poison. See docs/how-to-use.md, Troubleshooting."
  severity             = 2
  evaluation_frequency = "PT15M"
  window_duration      = "PT30M"
  tags                 = local.tags

  criteria {
    query                   = <<-KQL
      traces
      | where message startswith "sbom-poison-depth="
      | extend Depth = toint(split(message, "=")[1])
    KQL
    time_aggregation_method = "Maximum"
    metric_measure_column   = "Depth"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.sbom.id]
  }
}

# Enumeration not running at all: bad App key, App uninstalled, Function down.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "enumerate_missing" {
  name                 = "sbom-enumerate-not-succeeded"
  resource_group_name  = data.azurerm_resource_group.this.name
  location             = data.azurerm_resource_group.this.location
  scopes               = [azurerm_application_insights.collector.id]
  description          = "No successful enumerate_repos run in 26 hours. See docs/how-to-use.md, Troubleshooting."
  severity             = 2
  evaluation_frequency = "PT1H"
  window_duration      = "P1D"
  tags                 = local.tags

  criteria {
    query                   = <<-KQL
      requests
      | where timestamp > ago(26h)
      | where operation_Name == "enumerate_repos" and success == true
    KQL
    time_aggregation_method = "Count"
    operator                = "Equal"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.sbom.id]
  }
}

# The Container Apps environment sends its logs to the workspace itself.
resource "azurerm_monitor_diagnostic_setting" "sbom" {
  for_each = {
    function = { id = azurerm_function_app_flex_consumption.collector.id, category = "FunctionAppLogs", group = null }
    kv       = { id = azurerm_key_vault.this.id, category = null, group = "audit" }
    postgres = { id = azurerm_postgresql_flexible_server.dtrack.id, category = null, group = "allLogs" }
  }

  name                       = "to-log-sbom"
  target_resource_id         = each.value.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category       = each.value.category
    category_group = each.value.group
  }
}
