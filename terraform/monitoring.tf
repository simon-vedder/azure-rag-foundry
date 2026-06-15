# Diagnostics and alerts.
#
# All platform logs and metrics flow to the Log Analytics workspace already created in compute.tf.
# Metric alerts notify the action group below (add an email via the alert_email variable).

# ---------------------------------------------------------------------------
# Diagnostic settings -> Log Analytics
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "app" {
  name                       = "diag-to-law"
  target_resource_id         = module.app.web_app_id
  log_analytics_workspace_id = module.app.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "openai" {
  name                       = "diag-to-law"
  target_resource_id         = module.ai.openai_id
  log_analytics_workspace_id = module.app.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "search" {
  name                       = "diag-to-law"
  target_resource_id         = module.ai.search_id
  log_analytics_workspace_id = module.app.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

# Blob storage diagnostics live on the blob sub-resource, not the account itself.
resource "azurerm_monitor_diagnostic_setting" "storage_blob" {
  name                       = "diag-to-law"
  target_resource_id         = "${module.storage.id}/blobServices/default"
  log_analytics_workspace_id = module.app.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "Transaction"
  }
}

# ---------------------------------------------------------------------------
# Action group + metric alerts
# ---------------------------------------------------------------------------

resource "azurerm_monitor_action_group" "main" {
  name                = local.ag_name
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "ragalerts"

  dynamic "email_receiver" {
    for_each = var.alert_email != "" ? [1] : []
    content {
      name          = "ops"
      email_address = var.alert_email
    }
  }
}

resource "azurerm_monitor_metric_alert" "app_5xx" {
  name                = "${local.app_name}-5xx"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.app.web_app_id]
  description         = "App Service is returning server (5xx) errors."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 10
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

resource "azurerm_monitor_metric_alert" "app_latency" {
  name                = "${local.app_name}-latency"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.app.web_app_id]
  description         = "App Service average response time is high."
  severity            = 3
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "HttpResponseTime"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 5
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

resource "azurerm_monitor_metric_alert" "search_throttling" {
  name                = "${local.srch_name}-throttling"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.ai.search_id]
  description         = "AI Search is throttling queries — consider adding replicas."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.Search/searchServices"
    metric_name      = "ThrottledSearchQueriesPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 5
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

resource "azurerm_monitor_metric_alert" "openai_errors" {
  name                = "${local.oai_name}-errors"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.ai.openai_id]
  description         = "Azure OpenAI errors (includes 429 throttling / quota)."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.CognitiveServices/accounts"
    metric_name      = "TotalErrors"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 10
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}
