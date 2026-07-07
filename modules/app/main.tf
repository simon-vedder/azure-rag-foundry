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

  # Code is deployed by terraform_data.app_deploy below, not zip_deploy_file. azurerm only redeploys
  # zip_deploy_file when the *path* changes, and the archive path is constant — so a pure code change
  # (same path, new content) would silently never deploy. Keying an explicit `az webapp deploy` off
  # the archive's content hash makes every code change deploy deterministically.

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

# Deploys the application zip and redeploys whenever its content changes. triggers_replace keys off
# the archive's content hash, so this runs on the initial create and on every code change — closing
# the azurerm zip_deploy_file gap where a same-path/new-content change never redeploys. Requires the
# Azure CLI (already a prerequisite for the Search data plane) authenticated on the apply host.
resource "terraform_data" "app_deploy" {
  triggers_replace = [data.archive_file.app.output_base64sha256]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      az webapp deploy \
        --resource-group "${var.resource_group_name}" \
        --name "${var.app_name}" \
        --src-path "${data.archive_file.app.output_path}" \
        --type zip
    EOT
  }

  depends_on = [azurerm_linux_web_app.main]
}
