resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

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
  uami_name      = "${var.prefix}-id-${local.suffix}" # Easy Auth federated-credential identity
  ag_name        = "${var.prefix}-ag-${local.suffix}"
  entra_app_name = "${var.prefix}-rag-${local.suffix}"

  app_url = "https://${local.app_name}.azurewebsites.net"

  # Public access logic:
  # - No VNet integration: all backends publicly accessible (development mode).
  # - VNet integration + client IP detected: AI Search stays public but restricted to that IP,
  #   allowing terraform apply to manage data plane resources from the local machine.
  #   Other backends (OpenAI, Storage) are fully locked down via private endpoints.
  # - VNet integration + no client IP: all backends fully locked down (pipeline/jump box required).
  client_ip        = trimspace(data.http.my_ip.response_body)
  create_search_pe = var.enable_vnet_integration
  # AI Search public access is always enabled — access control is handled by IP firewall rules
  # (search_allowed_ips) when VNet integration is active, rather than fully disabling public access.
  # This allows terraform apply to manage data plane resources from the local machine in all modes.
  search_public_access = true
  search_allowed_ips   = var.enable_vnet_integration ? [local.client_ip] : []

  # Storage uses network rules (IP restriction + AzureServices bypass) instead of fully disabling
  # public access. This allows terraform apply to upload sample docs and lets the AI Search indexer
  # reach the storage account via the trusted Azure services bypass.
  storage_network_rules_enabled = var.enable_vnet_integration
  storage_allowed_ips           = var.enable_vnet_integration ? [local.client_ip] : []
}
