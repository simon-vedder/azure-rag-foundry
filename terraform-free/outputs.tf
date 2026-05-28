output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "app_service_name" {
  value = azurerm_linux_web_app.main.name
}

output "app_url" {
  value = local.app_url
}

output "openai_endpoint" {
  value = azurerm_cognitive_account.openai.endpoint
}

output "search_endpoint" {
  value = "https://${azurerm_search_service.main.name}.search.windows.net"
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "app_insights_connection_string" {
  value     = azurerm_application_insights.main.connection_string
  sensitive = true
}

output "entra_app_client_id" {
  value = azuread_application.main.client_id
}

output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "managed_identity_principal_id" {
  value = azurerm_linux_web_app.main.identity[0].principal_id
}
