terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

locals {
  # Embedding vector dimensions are derived from the selected model so the index
  # schema and the embedding skill always stay in sync.
  embedding_model_dimensions = {
    "text-embedding-3-small" = 1536
    "text-embedding-3-large" = 3072
    "text-embedding-ada-002" = 1536
  }
  embedding_dimensions = local.embedding_model_dimensions[var.embedding_model]
}

resource "azurerm_cognitive_account" "openai" {
  name                = var.openai_name
  location            = var.location
  resource_group_name = var.resource_group_name
  kind                = "OpenAI"
  sku_name            = "S0"
  # Required for private endpoint support and AAD token auth on Cognitive Services accounts.
  custom_subdomain_name = var.openai_name

  # Public access stays enabled so the AI Search indexer's AzureOpenAIEmbeddingSkill can reach
  # OpenAI. The indexer runs outside any VNet and cannot use a private endpoint. Access is still
  # secured by RBAC / keys; a private endpoint (root config) provides a private path for App
  # Service traffic from within the VNet.
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
  name                 = var.embedding_model
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.embedding_model
    version = "1"
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.embedding_capacity
  }
}

resource "azurerm_search_service" "main" {
  name                = var.search_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.search_sku

  public_network_access_enabled = var.search_public_network_access
  allowed_ips                   = var.search_allowed_ips

  local_authentication_enabled = var.search_local_auth_enabled
  semantic_search_sku          = var.semantic_search_sku

  dynamic "identity" {
    for_each = var.search_identity_enabled ? [1] : []
    content {
      type = "SystemAssigned"
    }
  }

  replica_count   = var.search_replica_count
  partition_count = var.search_partition_count
}
