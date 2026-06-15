# Dedicated user-assigned identity used ONLY as the Easy Auth federated-credential subject.
# Keeping it separate from the app's system-assigned identity (which holds the data-plane RBAC)
# means nothing beyond this app registration's login flow can authenticate as the Entra app.
resource "azurerm_user_assigned_identity" "easy_auth" {
  name                = local.uami_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# Entra ID app registration with generated per-topic app roles, plus all RBAC for the
# App Service managed identity. Role values follow <topic>.<Tier>.<Action> (e.g. hr.Internal.Read)
# and are decoded by the app to build the server-side search filter.
module "identity" {
  source = "../modules/identity"

  name             = local.entra_app_name
  app_url          = local.app_url
  topics           = var.topics
  tiers            = var.tiers
  public_tier_mode = var.public_tier_mode

  # Only users explicitly assigned an app role in Entra ID (directly or via a role group) can
  # authenticate. Any tenant user without an assignment is denied at the Easy Auth layer.
  require_role_assignment = true
  create_role_groups      = var.create_role_groups

  # Secretless Easy Auth: no client secret is created; Easy Auth authenticates as the app via a
  # federated credential trusting the user-assigned identity above.
  use_managed_identity_auth = true
  easy_auth_fic_subject     = azurerm_user_assigned_identity.easy_auth.principal_id
  tenant_id                 = data.azuread_client_config.current.tenant_id
}

# RBAC: App Service Managed Identity → Azure OpenAI
resource "azurerm_role_assignment" "app_openai" {
  scope                = module.ai.openai_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = module.app.principal_id
}

# RBAC: App Service Managed Identity → AI Search (read + query)
resource "azurerm_role_assignment" "app_search_reader" {
  scope                = module.ai.search_id
  role_definition_name = "Search Index Data Reader"
  principal_id         = module.app.principal_id
}

# RBAC: App Service Managed Identity → AI Search service administration.
# Required only for the document manager's "reindex now" button (POST /indexers/<name>/run is a
# service-administration operation with no narrower built-in role). Trade-off: this also allows
# the app identity to modify index definitions. Remove this assignment if you accept the hourly
# indexer schedule instead of on-demand reindexing.
resource "azurerm_role_assignment" "app_search_contributor" {
  scope                = module.ai.search_id
  role_definition_name = "Search Service Contributor"
  principal_id         = module.app.principal_id
}

# RBAC: App Service Managed Identity → Storage.
# Contributor (not Reader) because the in-app document manager uploads blobs, sets the IsDeleted
# soft-delete metadata, and writes the topic/access_level metadata the search index relies on.
resource "azurerm_role_assignment" "app_storage" {
  scope                = module.storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.app.principal_id
}
