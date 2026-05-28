# App Registration for Easy Auth (Entra ID authentication on the web app)
resource "azuread_application" "main" {
  display_name     = local.entra_app_name
  sign_in_audience = "AzureADMyOrg"

  app_role {
    allowed_member_types = ["User"]
    description          = "Can read internal-level documents"
    display_name         = "Internal Reader"
    enabled              = true
    id                   = random_uuid.internal_read_role.result
    value                = "Internal.Read"
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Can read confidential-level documents"
    display_name         = "Confidential Reader"
    enabled              = true
    id                   = random_uuid.confidential_read_role.result
    value                = "Confidential.Read"
  }

  web {
    homepage_url  = local.app_url
    redirect_uris = ["${local.app_url}/.auth/login/aad/callback"]

    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = true
    }
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph

    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "main" {
  client_id                    = azuread_application.main.client_id
  app_role_assignment_required = true
}

resource "azuread_application_password" "easy_auth" {
  application_id = azuread_application.main.id
  display_name   = "easy-auth"
  end_date       = "2099-01-01T00:00:00Z"
}

# RBAC: App Service Managed Identity → Azure OpenAI
resource "azurerm_role_assignment" "app_openai" {
  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_linux_web_app.main.identity[0].principal_id
}

# RBAC: App Service Managed Identity → Storage (read documents)
resource "azurerm_role_assignment" "app_storage" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_linux_web_app.main.identity[0].principal_id
}
