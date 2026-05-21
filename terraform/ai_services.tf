resource "azurerm_cognitive_account" "openai" {
  name                = local.oai_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  kind                = "OpenAI"
  sku_name            = "S0"

  public_network_access_enabled = local.backend_public_access
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
  sku                 = var.search_sku

  public_network_access_enabled = local.search_public_access

  # Enable Azure AD (RBAC) auth in addition to API keys
  authentication_failure_mode = "http403"
  local_authentication_enabled = true

  # Free tier supports only 1 replica and 1 partition
  replica_count   = var.search_sku == "free" ? 1 : 1 # PROD UPGRADE: increase replica_count for HA
  partition_count = var.search_sku == "free" ? 1 : 1
}
