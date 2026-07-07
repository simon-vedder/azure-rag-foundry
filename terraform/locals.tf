resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix         = random_string.suffix.result
  rg_name        = "${var.prefix}-rg-${local.suffix}"
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
  entra_app_name = "${var.prefix}-auth-${local.suffix}"

  app_url = "https://${local.app_name}.azurewebsites.net"

  # Public access logic (VNet integration on = production/private posture):
  # - No VNet integration (dev): all backends publicly accessible over RBAC — simplest to deploy.
  # - VNet integration on: only the App Service is reachable from the internet. OpenAI is fully
  #   private (App Service via private endpoint, the AI Search indexer via a shared private link).
  #   AI Search and Storage keep public access enabled but deny everything except the deployer's IP,
  #   so terraform apply can still provision the Search data plane and upload sample docs from a
  #   laptop; the AI Search indexer reaches Storage over a shared private link, not the public path.
  client_ip        = trimspace(data.http.my_ip.response_body)
  create_search_pe = var.enable_vnet_integration

  # AI Search: kept publicly reachable but firewalled to the deployer IP when private, so the data
  # plane (index/skillset/indexer) can be managed without a VNet-connected runner.
  search_public_access = true
  search_allowed_ips   = var.enable_vnet_integration ? [local.client_ip] : []

  # OpenAI: no deployer-side data-plane call at apply time (model deployments are control plane), so
  # it can go fully private when VNet integration is on.
  openai_public_access = !var.enable_vnet_integration

  # Storage: deny-all-except-deployer-IP when private, with the trusted-services bypass dropped so
  # the indexer must use its shared private link rather than the broad AzureServices path.
  storage_network_rules_enabled = var.enable_vnet_integration
  storage_allowed_ips           = var.enable_vnet_integration ? [local.client_ip] : []
}
