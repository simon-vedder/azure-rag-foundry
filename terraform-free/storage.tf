module "storage" {
  source = "../modules/storage"

  name                = local.st_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  # Public access, no network rules — the free demo keeps everything reachable. The indexer reads
  # blobs via the storage connection string (see search_dataplane.tf).
  network_rules_enabled = false

  topics           = var.topics
  tiers            = var.tiers
  sample_docs_path = "${path.module}/../sample-docs"
}
