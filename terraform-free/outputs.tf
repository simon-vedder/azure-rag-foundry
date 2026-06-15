output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "app_service_name" {
  value = module.app.web_app_name
}

output "app_url" {
  value = local.app_url
}

output "openai_endpoint" {
  value = module.ai.openai_endpoint
}

output "search_endpoint" {
  value = module.ai.search_endpoint
}

output "storage_account_name" {
  value = module.storage.name
}

output "app_insights_connection_string" {
  value     = module.app.app_insights_connection_string
  sensitive = true
}

output "entra_app_client_id" {
  value = module.identity.client_id
}

# role value => { group name, object id }. Add members to these groups to grant access
# (empty when create_role_groups = false).
output "role_groups" {
  value = module.identity.role_groups
}

output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "managed_identity_principal_id" {
  value = module.app.principal_id
}
