output "id" {
  value = azurerm_storage_account.main.id
}

output "name" {
  value = azurerm_storage_account.main.name
}

output "container_name" {
  value = azurerm_storage_container.documents.name
}

output "container_id" {
  value = azurerm_storage_container.documents.id
}

output "primary_connection_string" {
  value     = azurerm_storage_account.main.primary_connection_string
  sensitive = true
}
