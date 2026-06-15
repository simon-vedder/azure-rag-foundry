output "openai_id" {
  value = azurerm_cognitive_account.openai.id
}

output "openai_endpoint" {
  value = azurerm_cognitive_account.openai.endpoint
}

output "openai_primary_key" {
  value     = azurerm_cognitive_account.openai.primary_access_key
  sensitive = true
}

output "chat_deployment_name" {
  value = azurerm_cognitive_deployment.chat.name
}

output "embedding_deployment_name" {
  value = azurerm_cognitive_deployment.embedding.name
}

output "embedding_dimensions" {
  value = local.embedding_dimensions
}

output "search_id" {
  value = azurerm_search_service.main.id
}

output "search_name" {
  value = azurerm_search_service.main.name
}

output "search_endpoint" {
  value = "https://${azurerm_search_service.main.name}.search.windows.net"
}

output "search_principal_id" {
  value = var.search_identity_enabled ? azurerm_search_service.main.identity[0].principal_id : null
}

output "search_primary_key" {
  value     = azurerm_search_service.main.primary_key
  sensitive = true
}
