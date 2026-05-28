resource "azurerm_cognitive_account" "openai" {
  name                  = local.oai_name
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  # Required for private endpoint support on Cognitive Services accounts.
  custom_subdomain_name = local.oai_name

  # Public access stays enabled so the AI Search indexer's AzureOpenAIEmbeddingSkill can reach OpenAI.
  # The indexer runs outside the VNet and cannot use the private endpoint.
  # Access is still secured by RBAC (managed identity); the private endpoint provides
  # a private path for App Service traffic from within the VNet.
  public_network_access_enabled = true
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.openai_model
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.openai_model
    version = var.openai_model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.openai_capacity
  }
}

resource "azurerm_cognitive_deployment" "embedding" {
  name                 = "text-embedding-3-small"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "text-embedding-3-small"
    version = "1"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 10
  }
}

resource "azurerm_search_service" "main" {
  name                = local.srch_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "standard"

  public_network_access_enabled = local.search_public_access
  allowed_ips                   = local.search_allowed_ips

  local_authentication_enabled = false
  semantic_search_sku          = "free"

  identity {
    type = "SystemAssigned"
  }

  replica_count   = 1 # PROD UPGRADE: increase for HA
  partition_count = 1
}

# RBAC: Search service managed identity → Storage (read blobs for indexing).
resource "azurerm_role_assignment" "search_storage" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_search_service.main.identity[0].principal_id
}

# RBAC: Search service managed identity → Azure OpenAI (embedding skill in indexer pipeline).
resource "azurerm_role_assignment" "search_openai" {
  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_search_service.main.identity[0].principal_id
}
