# Dedicated user-assigned identity used ONLY as the Easy Auth federated-credential subject, so the
# free tier also runs secretless Easy Auth (no client secret in plain app settings or state).
resource "azurerm_user_assigned_identity" "easy_auth" {
  name                = local.uami_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# Entra app registration with generated per-topic app roles (same module as the secure baseline).
module "identity" {
  source = "../modules/identity"

  name             = local.entra_app_name
  app_url          = local.app_url
  topics           = var.topics
  tiers            = var.tiers
  public_tier_mode = var.public_tier_mode

  require_role_assignment = true
  create_role_groups      = var.create_role_groups

  # Secretless Easy Auth via a federated credential trusting the user-assigned identity above.
  use_managed_identity_auth = true
  easy_auth_fic_subject     = azurerm_user_assigned_identity.easy_auth.principal_id
  tenant_id                 = data.azuread_client_config.current.tenant_id
}

# RBAC for the App Service managed identity. Search is accessed with the admin key (free tier has
# no managed identity), so the only role assignments needed are for OpenAI and Storage, which both
# support managed identity regardless of the Search tier.

# App Service Managed Identity → Azure OpenAI (chat + embedding at query time).
resource "azurerm_role_assignment" "app_openai" {
  scope                = module.ai.openai_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = module.app.principal_id
}

# App Service Managed Identity → Storage. Contributor (not Reader) because the in-app document
# manager uploads blobs and writes the topic/access_level/IsDeleted metadata the index relies on.
resource "azurerm_role_assignment" "app_storage" {
  scope                = module.storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.app.principal_id
}
