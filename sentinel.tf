locals {
  # /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>
  cps_workspace_rg   = split("/", var.cps_workspace_id)[4]
  cps_workspace_name = split("/", var.cps_workspace_id)[8]

  kql_dir = "${path.module}/sbom-collector/kql"

  # One column list per table, shared by the table schema and the DCR stream
  # declaration so the two can't drift ("Sentinel rows missing, no errors"
  # in the runbook is usually exactly that drift).
  sbom_columns = [
    { name = "TimeGenerated", type = "datetime" },
    { name = "Org", type = "string" },
    { name = "Repo", type = "string" },
    { name = "Branch", type = "string" },
    { name = "PackageName", type = "string" },
    { name = "PackageVersion", type = "string" },
    { name = "Purl", type = "string" },
    { name = "Ecosystem", type = "string" },
    { name = "License", type = "string" },
  ]

  sbom_run_columns = [
    { name = "TimeGenerated", type = "datetime" },
    { name = "Org", type = "string" },
    { name = "Repo", type = "string" },
    { name = "Status", type = "string" },
    { name = "ComponentCount", type = "int" },
    { name = "PushedAt", type = "datetime" },
    { name = "Detail", type = "string" },
    # Phase 3: open Dependabot alerts by severity at collection time.
    { name = "DependabotCritical", type = "int" },
    { name = "DependabotHigh", type = "int" },
    { name = "DependabotMedium", type = "int" },
    { name = "DependabotLow", type = "int" },
  ]

  sentinel_tables = {
    GitHubSbom    = { columns = local.sbom_columns, retention = 90 }
    GitHubSbomRun = { columns = local.sbom_run_columns, retention = 365 }
  }
}

# ---------- Tables and ingestion (Phase 1) ----------

resource "azapi_resource" "sentinel_table" {
  for_each = local.sentinel_tables

  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "${each.key}_CL"
  parent_id = var.cps_workspace_id

  body = {
    properties = {
      plan            = "Analytics"
      retentionInDays = each.value.retention
      schema = {
        name    = "${each.key}_CL"
        columns = each.value.columns
      }
    }
  }
}

resource "azurerm_monitor_data_collection_endpoint" "sbom" {
  name                          = "dce-sbom-${local.env}"
  resource_group_name           = data.azurerm_resource_group.this.name
  location                      = data.azurerm_resource_group.this.location
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_monitor_data_collection_rule" "sbom" {
  name                        = "dcr-sbom-${local.env}"
  resource_group_name         = data.azurerm_resource_group.this.name
  location                    = data.azurerm_resource_group.this.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.sbom.id
  tags                        = local.tags

  destinations {
    log_analytics {
      name                  = "cpsSentinel"
      workspace_resource_id = var.cps_workspace_id
    }
  }

  dynamic "stream_declaration" {
    for_each = local.sentinel_tables
    content {
      stream_name = "Custom-${stream_declaration.key}"
      dynamic "column" {
        for_each = stream_declaration.value.columns
        content {
          name = column.value.name
          type = column.value.type
        }
      }
    }
  }

  dynamic "data_flow" {
    for_each = local.sentinel_tables
    content {
      streams       = ["Custom-${data_flow.key}"]
      destinations  = ["cpsSentinel"]
      transform_kql = "source"
      output_stream = "Custom-${data_flow.key}_CL"
    }
  }

  depends_on = [azapi_resource.sentinel_table]
}

# ---------- Saved function, workbook, watchlist, analytics rule (Phase 2) ----------

resource "azurerm_log_analytics_saved_search" "sbom_latest" {
  name                       = "SbomLatest"
  log_analytics_workspace_id = var.cps_workspace_id
  category                   = "SBOM"
  display_name               = "SbomLatest"
  function_alias             = "SbomLatest"
  query                      = file("${local.kql_dir}/SbomLatest.kql")

  depends_on = [azapi_resource.sentinel_table]
}

resource "azurerm_application_insights_workbook" "sbom" {
  # Workbook names must be GUIDs; uuidv5 keeps it stable across applies.
  name                = uuidv5("url", "https://github.com/sg-cloud-platform/cps-security-platform-infra/workbooks/sbom-${local.env}")
  resource_group_name = local.cps_workspace_rg
  location            = data.azurerm_resource_group.this.location
  display_name        = "SBOM coverage and inventory"
  source_id           = lower(var.cps_workspace_id)
  category            = "sentinel"
  tags                = local.tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = concat(
      [{
        type = 1
        name = "intro"
        content = {
          json = "Nightly GitHub dependency-graph SBOMs for every repo in the enterprise. **Default branch only — not necessarily what is deployed.** Data is OFFICIAL-SENSITIVE."
        }
      }],
      [for tile in [
        { name = "coverage", title = "Coverage by org", kql = "coverage-by-org.kql" },
        { name = "stale", title = "Stale or failed repos", kql = "stale-or-failed.kql" },
        { name = "licence", title = "Licence watch", kql = "licence-watch.kql" },
        { name = "sprawl", title = "Version sprawl", kql = "version-sprawl.kql" },
        { name = "dependabot", title = "Open Dependabot alerts by org", kql = "dependabot-by-org.kql" },
        ] : {
        type = 3
        name = tile.name
        content = {
          version       = "KqlItem/1.0"
          title         = tile.title
          query         = file("${local.kql_dir}/${tile.kql}")
          size          = 0
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "table"
        }
      }],
    )
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  })

  depends_on = [azurerm_log_analytics_saved_search.sbom_latest]
}

resource "azurerm_sentinel_watchlist" "banned_packages" {
  name                       = "BannedPackages"
  log_analytics_workspace_id = var.cps_workspace_id
  display_name               = "Banned packages"
  description                = "Packages that must not run anywhere in the estate. Matched against SbomLatest by the 'SBOM: banned package in use' analytics rule."
  item_search_key            = "PackageName"
}

resource "azurerm_sentinel_watchlist_item" "banned_packages" {
  for_each = { for p in var.banned_packages : p.PackageName => p }

  watchlist_id = azurerm_sentinel_watchlist.banned_packages.id
  properties = {
    PackageName = each.value.PackageName
    Reason      = each.value.Reason
  }
}

resource "azurerm_sentinel_alert_rule_scheduled" "banned_package" {
  name                       = "sbom-banned-package-in-use"
  log_analytics_workspace_id = var.cps_workspace_id
  display_name               = "SBOM: banned package in use"
  description                = "A repo's latest SBOM contains a package on the BannedPackages watchlist."
  severity                   = "High"
  query                      = file("${local.kql_dir}/banned-packages.kql")

  # SBOMs land nightly. SbomLatest looks back 8 days itself, so the rule's
  # query period has to cover that too.
  query_frequency   = "P1D"
  query_period      = "P8D"
  trigger_operator  = "GreaterThan"
  trigger_threshold = 0

  event_grouping {
    aggregation_method = "AlertPerResult"
  }

  incident {
    create_incident_enabled = true
    grouping {
      enabled                 = true
      lookback_duration       = "P7D"
      entity_matching_method  = "Selected"
      by_custom_details       = ["Org", "Repo", "PackageName"]
      reopen_closed_incidents = false
    }
  }

  custom_details = {
    Org         = "Org"
    Repo        = "Repo"
    PackageName = "PackageName"
    Version     = "PackageVersion"
    Reason      = "Reason"
  }

  depends_on = [azurerm_log_analytics_saved_search.sbom_latest, azurerm_sentinel_watchlist.banned_packages]
}
