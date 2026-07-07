module "storage" {
  source = "../modules/storage"

  name                = local.st_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  network_rules_enabled = local.storage_network_rules_enabled
  allowed_ips           = local.storage_allowed_ips
  # Indexer reaches blobs over a shared private link (see network.tf), not the trusted-services path.
  trusted_services_bypass = false

  topics           = var.topics
  tiers            = var.tiers
  sample_docs_path = "${path.module}/../sample-docs"
}
