resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "random_uuid" "internal_read_role" {}
resource "random_uuid" "confidential_read_role" {}

locals {
  suffix         = random_string.suffix.result
  rg_name        = "${var.prefix}-rag-rg-${local.suffix}"
  oai_name       = "${var.prefix}-oai-${local.suffix}"
  srch_name      = "${var.prefix}-srch-${local.suffix}"
  st_name        = "${var.prefix}st${local.suffix}" # max 24 chars, alphanumeric only
  asp_name       = "${var.prefix}-asp-${local.suffix}"
  app_name       = "${var.prefix}-app-${local.suffix}"
  vnet_name      = "${var.prefix}-vnet-${local.suffix}"
  law_name       = "${var.prefix}-law-${local.suffix}"
  appi_name      = "${var.prefix}-appi-${local.suffix}"
  entra_app_name = "${var.prefix}-rag-${local.suffix}"

  app_url = "https://${local.app_name}.azurewebsites.net"

  # Private endpoints and public-access disabling are only applied when VNet integration is enabled.
  # In test (B1): App Service reaches backend via public endpoints using Managed Identity RBAC.
  # In prod (P1v3 + enable_vnet_integration=true): private endpoints + public access disabled.
  create_search_pe      = var.enable_vnet_integration && var.search_sku != "free"
  backend_public_access = !var.enable_vnet_integration
  search_public_access  = var.search_sku == "free" ? true : !var.enable_vnet_integration

  # Branding — detect logo file in repo root branding/ folder (png > svg > jpg)
  logo_path = (
    fileexists("${path.module}/../branding/logo.png") ? "${path.module}/../branding/logo.png" :
    fileexists("${path.module}/../branding/logo.svg") ? "${path.module}/../branding/logo.svg" :
    fileexists("${path.module}/../branding/logo.jpg") ? "${path.module}/../branding/logo.jpg" :
    ""
  )
  logo_name = local.logo_path != "" ? basename(local.logo_path) : ""
  logo_content_type = (
    endswith(local.logo_name, ".svg") ? "image/svg+xml" :
    endswith(local.logo_name, ".jpg") ? "image/jpeg" :
    "image/png"
  )
  branding_logo_url = local.logo_name != "" ? "https://${local.st_name}.blob.core.windows.net/branding/${local.logo_name}" : ""
}
