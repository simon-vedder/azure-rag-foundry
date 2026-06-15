output "web_app_id" {
  value = azurerm_linux_web_app.main.id
}

output "web_app_name" {
  value = azurerm_linux_web_app.main.name
}

output "principal_id" {
  value = azurerm_linux_web_app.main.identity[0].principal_id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "app_insights_connection_string" {
  value     = azurerm_application_insights.main.connection_string
  sensitive = true
}
