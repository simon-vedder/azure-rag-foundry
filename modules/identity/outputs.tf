output "client_id" {
  value = azuread_application.main.client_id
}

output "application_id" {
  value = azuread_application.main.id
}

output "service_principal_object_id" {
  value = azuread_service_principal.main.object_id
}

# Null when use_managed_identity_auth = true (no secret is created).
output "client_secret" {
  value     = one(azuread_application_password.easy_auth[*].value)
  sensitive = true
}

output "client_secret_end_date" {
  value = one(azuread_application_password.easy_auth[*].end_date)
}

output "app_role_values" {
  value = keys(local.app_roles)
}

# role value => group display name / object id, so admins know exactly which group feeds which role.
output "role_groups" {
  value = {
    for role_value, group in azuread_group.role :
    role_value => { name = group.display_name, object_id = group.object_id }
  }
}
