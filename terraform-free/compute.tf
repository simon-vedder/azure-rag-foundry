module "app" {
  source = "../modules/app"

  app_name            = local.app_name
  plan_name           = local.asp_name
  log_analytics_name  = local.law_name
  app_insights_name   = local.appi_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku_name            = "B1"

  source_dir      = "${path.module}/../app"
  zip_output_path = "${path.module}/../deploy-free.zip"

  # No VNet integration on the free demo.
  vnet_subnet_id = null

  auth_client_id = module.identity.client_id
  auth_tenant_id = data.azuread_client_config.current.tenant_id

  # Secretless Easy Auth: attach the federated-credential identity and point Easy Auth at the MI
  # override setting instead of a client secret.
  user_assigned_identity_id       = azurerm_user_assigned_identity.easy_auth.id
  auth_client_secret_setting_name = "OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID"
  sticky_app_setting_names        = ["OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID"]

  app_settings = {
    AZURE_OPENAI_ENDPOINT             = module.ai.openai_endpoint
    AZURE_OPENAI_CHAT_DEPLOYMENT      = module.ai.chat_deployment_name
    AZURE_OPENAI_EMBEDDING_DEPLOYMENT = module.ai.embedding_deployment_name
    AZURE_SEARCH_ENDPOINT             = module.ai.search_endpoint
    AZURE_SEARCH_INDEX                = module.search_dataplane.index_name
    AZURE_SEARCH_INDEXER              = module.search_dataplane.indexer_name
    AZURE_SEARCH_SEMANTIC_ENABLED     = "false"
    AZURE_STORAGE_ACCOUNT             = module.storage.name
    DOCUMENTS_CONTAINER               = module.storage.container_name
    COMPANY_NAME                      = var.company_name
    TOPICS                            = jsonencode(var.topics)
    TIERS                             = jsonencode(var.tiers)
    PUBLIC_TIER_MODE                  = var.public_tier_mode

    # Free tier: the app queries Search and runs the indexer with the admin key (no managed identity).
    AZURE_SEARCH_API_KEY = module.ai.search_primary_key

    # Easy Auth is secretless (federated credential): this is the MI's client id, not a secret.
    OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID = azurerm_user_assigned_identity.easy_auth.client_id
  }
}
