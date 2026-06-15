terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    archive = {
      source = "hashicorp/archive"
    }
  }
}

data "archive_file" "app" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = var.zip_output_path
  excludes    = ["__pycache__", ".env"]
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = var.log_analytics_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "main" {
  name                = var.app_insights_name
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
}

resource "azurerm_service_plan" "main" {
  name                = var.plan_name
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  sku_name            = var.sku_name
}

resource "azurerm_linux_web_app" "main" {
  name                = var.app_name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.main.id
  zip_deploy_file     = data.archive_file.app.output_path

  virtual_network_subnet_id = var.vnet_subnet_id

  # System-assigned identity holds the data-plane RBAC (OpenAI, Search, Storage). An optional
  # user-assigned identity is attached purely as the Easy Auth federated-credential subject.
  identity {
    type         = var.user_assigned_identity_id == null ? "SystemAssigned" : "SystemAssigned, UserAssigned"
    identity_ids = var.user_assigned_identity_id == null ? null : [var.user_assigned_identity_id]
  }

  site_config {
    application_stack {
      python_version = "3.12"
    }
    app_command_line = "python -m uvicorn app:app --host 0.0.0.0 --port 8000"
    # Routes all outbound traffic through the VNet when VNet integration is active.
    vnet_route_all_enabled = var.vnet_subnet_id != null
  }

  app_settings = merge(var.app_settings, {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.main.connection_string
    SCM_DO_BUILD_DURING_DEPLOYMENT        = "true"
    WEBSITES_PORT                         = "8000"
  })

  auth_settings_v2 {
    auth_enabled = true
    # require_authentication = true makes Easy Auth enforce the unauthenticated_action (redirect to
    # login) for every request. Without it the platform allows anonymous requests through to the app,
    # which then only fails closed with its own 401 — secure, but no sign-in redirect.
    require_authentication = true
    unauthenticated_action = "RedirectToLoginPage"
    default_provider       = "azureactivedirectory"

    active_directory_v2 {
      client_id                  = var.auth_client_id
      tenant_auth_endpoint       = "https://login.microsoftonline.com/${var.auth_tenant_id}/v2.0"
      client_secret_setting_name = var.auth_client_secret_setting_name
      allowed_audiences          = [var.auth_client_id]
    }

    login {
      token_store_enabled = true
    }
  }

  # Mark the Easy Auth MI override setting slot-sticky, per Microsoft guidance, so it doesn't swap
  # with a deployment slot. No-op when the list is empty (secret-based auth).
  dynamic "sticky_settings" {
    for_each = length(var.sticky_app_setting_names) > 0 ? [1] : []
    content {
      app_setting_names = var.sticky_app_setting_names
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

  lifecycle {
    precondition {
      condition     = var.vnet_subnet_id == null || !contains(["F1", "FREE", "D1", "SHARED"], upper(var.sku_name))
      error_message = "VNet integration requires a Basic-tier or higher App Service SKU; Free/Shared SKUs (F1, D1) do not support it."
    }
  }
}
