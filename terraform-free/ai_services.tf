# Azure OpenAI + AI Search (free tier).
#
# Free-tier Search cannot disable local auth and has no managed identity, so everything
# downstream authenticates with keys: the data plane uses the admin key, the embedding skill uses
# the OpenAI key, and the indexer's datasource uses the storage connection string. Semantic ranking
# is not available on the free tier, so it stays disabled.
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

  search_sku                   = "free"
  search_local_auth_enabled    = true  # free tier cannot disable API keys
  search_identity_enabled      = false # no managed identity on the free tier
  search_public_network_access = true
  semantic_search_sku          = null # semantic ranker unavailable on the free tier
}
