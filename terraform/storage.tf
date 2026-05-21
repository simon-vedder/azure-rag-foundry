resource "azurerm_storage_account" "main" {
  name                     = local.st_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  public_network_access_enabled   = local.backend_public_access
  allow_nested_items_to_be_public = true # required for public branding container
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
}

resource "azurerm_storage_container" "documents" {
  name                  = "documents"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "branding" {
  name                  = "branding"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "blob" # individual blobs publicly readable (logo only)
}

resource "azurerm_storage_blob" "logo" {
  count                  = local.logo_name != "" ? 1 : 0
  name                   = local.logo_name != "" ? local.logo_name : "logo.png"
  storage_account_name   = azurerm_storage_account.main.name
  storage_container_name = azurerm_storage_container.branding.name
  type                   = "Block"
  source                 = local.logo_path != "" ? local.logo_path : null
  content_type           = local.logo_content_type
}
