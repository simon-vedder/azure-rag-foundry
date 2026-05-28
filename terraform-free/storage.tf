resource "azurerm_storage_account" "main" {
  name                     = local.st_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
}

resource "azurerm_storage_container" "documents" {
  name                  = "documents"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}


# Sample documents — uploaded on first apply to give new deployments something to search against.
# Replace or supplement these by uploading your own files to the relevant blob folder.
locals {
  sample_docs = {
    "public/company-overview.txt"                             = "${path.module}/../sample-docs/public/company-overview.txt"
    "internal/product-roadmap-2026.txt"                       = "${path.module}/../sample-docs/internal/product-roadmap-2026.txt"
    "confidential/executive-compensation-and-ma-strategy.txt" = "${path.module}/../sample-docs/confidential/executive-compensation-and-ma-strategy.txt"
  }
}

resource "azurerm_storage_blob" "sample_docs" {
  for_each = local.sample_docs

  name                   = each.key
  storage_account_name   = azurerm_storage_account.main.name
  storage_container_name = azurerm_storage_container.documents.name
  type                   = "Block"
  source                 = each.value
  content_type           = "text/plain"
}
