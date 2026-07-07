terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

resource "azurerm_storage_account" "main" {
  name                     = var.name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Public access stays enabled so terraform can upload sample docs from the deployer's IP, but when
  # network rules are on the account denies everything except that IP. Backend traffic is private:
  # App Service reaches blobs over the blob private endpoint and, with trusted_services_bypass off,
  # the AI Search indexer reaches them over a shared private link rather than the broad
  # AzureServices trusted-services bypass.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"

  dynamic "network_rules" {
    for_each = var.network_rules_enabled ? [1] : []
    content {
      default_action = "Deny"
      ip_rules       = var.allowed_ips
      bypass         = var.trusted_services_bypass ? ["AzureServices"] : ["None"]
    }
  }
}

resource "azurerm_storage_container" "documents" {
  name                  = "documents"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

# Sample documents — uploaded on first apply so a fresh deployment is immediately demoable.
# Blob layout: <topic>/<access_level>/<file>. The topic and access_level blob metadata are the
# authoritative source for the search index (the folder path is convention for humans); a blob
# without this metadata is never returned by any query — fail closed.
locals {
  sample_files = var.sample_docs_path == "" ? [] : [
    for f in fileset(var.sample_docs_path, "*/*/*") : f
    if contains(keys(var.topics), split("/", f)[0]) && contains(var.tiers, split("/", f)[1])
  ]

  content_types = {
    "txt" = "text/plain"
    "md"  = "text/markdown"
    "csv" = "text/csv"
    "pdf" = "application/pdf"
  }
}

resource "azurerm_storage_blob" "sample_docs" {
  for_each = toset(local.sample_files)

  name                   = each.value
  storage_account_name   = azurerm_storage_account.main.name
  storage_container_name = azurerm_storage_container.documents.name
  type                   = "Block"
  source                 = "${var.sample_docs_path}/${each.value}"
  content_type           = lookup(local.content_types, element(split(".", each.value), length(split(".", each.value)) - 1), "application/octet-stream")

  metadata = {
    topic        = split("/", each.value)[0]
    access_level = split("/", each.value)[1]
  }
}
