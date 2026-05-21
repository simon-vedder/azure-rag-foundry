resource "azurerm_log_analytics_workspace" "main" {
  name                = local.law_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "main" {
  name                = local.appi_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
}

resource "azurerm_service_plan" "main" {
  name                = local.asp_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = var.app_service_sku
}

resource "azurerm_linux_web_app" "main" {
  name                = local.app_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id

  # PROD: enable VNet integration by setting enable_vnet_integration = true and upgrading app_service_sku to P1v3
  virtual_network_subnet_id = var.enable_vnet_integration ? azurerm_subnet.app.id : null

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.12"
    }
    app_command_line = "python -m uvicorn app:app --host 0.0.0.0 --port 8000"
  }

  app_settings = {
    AZURE_OPENAI_ENDPOINT                    = azurerm_cognitive_account.openai.endpoint
    AZURE_OPENAI_CHAT_DEPLOYMENT             = azurerm_cognitive_deployment.chat.name
    AZURE_OPENAI_EMBEDDING_DEPLOYMENT        = azurerm_cognitive_deployment.embedding.name
    AZURE_SEARCH_ENDPOINT                    = "https://${azurerm_search_service.main.name}.search.windows.net"
    AZURE_STORAGE_ACCOUNT                    = azurerm_storage_account.main.name
    AZURE_SEARCH_SEMANTIC_ENABLED            = var.search_sku != "free" ? "true" : "false"
    APPLICATIONINSIGHTS_CONNECTION_STRING    = azurerm_application_insights.main.connection_string
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = azuread_application_password.easy_auth.value
    SCM_DO_BUILD_DURING_DEPLOYMENT           = "true"
    WEBSITES_PORT                            = "8000"
    COMPANY_NAME                             = var.company_name
    LOGO_URL                                 = local.branding_logo_url
  }

  auth_settings_v2 {
    auth_enabled           = true
    unauthenticated_action = "RedirectToLoginPage"
    default_provider       = "azureactivedirectory"

    active_directory_v2 {
      client_id                  = azuread_application.main.client_id
      tenant_auth_endpoint       = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"
      client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
      allowed_audiences          = [azuread_application.main.client_id]
    }

    login {
      token_store_enabled = true
    }
  }

  logs {
    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }
}
