module "ai" {
  source = "../modules/ai"

  openai_name         = local.oai_name
  search_name         = local.srch_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  openai_model         = var.openai_model
  openai_model_version = var.openai_model_version
  openai_capacity      = var.openai_capacity
  embedding_model      = var.embedding_model

  search_sku             = "standard"
  search_replica_count   = var.search_replica_count
  search_partition_count = var.search_partition_count

  # API keys disabled — RBAC-only auth via managed identities.
  search_local_auth_enabled    = false
  search_identity_enabled      = true
  search_public_network_access = local.search_public_access
  search_allowed_ips           = local.search_allowed_ips
  openai_public_network_access = local.openai_public_access
  semantic_search_sku          = "free"
}

# RBAC: Search service managed identity → Storage (read blobs for indexing).
resource "azurerm_role_assignment" "search_storage" {
  scope                = module.storage.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = module.ai.search_principal_id
}

# RBAC: Search service managed identity → Azure OpenAI (embedding skill in indexer pipeline).
resource "azurerm_role_assignment" "search_openai" {
  scope                = module.ai.openai_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = module.ai.search_principal_id
}

# The Search data plane (index/datasource/skillset/indexer) is provisioned from the machine running
# terraform via `az rest`, and Search local auth is disabled — so the deployer's own identity needs
# Search data-plane RBAC, scoped to this search service only.
resource "azurerm_role_assignment" "deployer_search_contributor" {
  scope                = module.ai.search_id
  role_definition_name = "Search Service Contributor"
  principal_id         = data.azuread_client_config.current.object_id
}

resource "azurerm_role_assignment" "deployer_search_index" {
  scope                = module.ai.search_id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = data.azuread_client_config.current.object_id
}

# RBAC is eventually consistent — let the deployer assignments propagate before the data-plane
# provisioner calls the Search REST API, otherwise the first apply can fail with 403.
resource "time_sleep" "search_rbac_propagation" {
  depends_on = [
    azurerm_role_assignment.deployer_search_contributor,
    azurerm_role_assignment.deployer_search_index,
  ]
  create_duration = "60s"
}
