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
  law_name       = "${var.prefix}-law-${local.suffix}"
  appi_name      = "${var.prefix}-appi-${local.suffix}"
  uami_name      = "${var.prefix}-id-${local.suffix}" # Easy Auth federated-credential identity
  entra_app_name = "${var.prefix}-rag-${local.suffix}"

  app_url = "https://${local.app_name}.azurewebsites.net"
}
