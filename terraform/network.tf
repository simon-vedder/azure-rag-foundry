resource "azurerm_virtual_network" "main" {
  name                = local.vnet_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/16"]
}

# Reserved for App Service VNet integration (unused in test with B1 SKU)
resource "azurerm_subnet" "app" {
  name                 = "app-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]

  delegation {
    name = "appservice"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "private-endpoint-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Private DNS Zones (always created; resolved by VNet only when VNet integration is active)
resource "azurerm_private_dns_zone" "openai" {
  name                = "privatelink.openai.azure.com"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone" "search" {
  name                = "privatelink.search.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "openai" {
  name                  = "openai-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.openai.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "search" {
  name                  = "search-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.search.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "blob-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

# Private Endpoints — only created when VNet integration is enabled
resource "azurerm_private_endpoint" "openai" {
  count               = var.enable_vnet_integration ? 1 : 0
  name                = "${local.oai_name}-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  # Wait for the OpenAI account to finish provisioning (its model deployments only complete once the
  # account reaches Succeeded) — attaching a private endpoint while it is still "Accepted" 400s.
  depends_on = [module.ai]

  private_service_connection {
    name                           = "${local.oai_name}-psc"
    private_connection_resource_id = module.ai.openai_id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "openai-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.openai.id]
  }
}

# Search PE only when VNet integration is on AND search SKU supports private endpoints (not free)
resource "azurerm_private_endpoint" "search" {
  count               = local.create_search_pe ? 1 : 0
  name                = "${local.srch_name}-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${local.srch_name}-psc"
    private_connection_resource_id = module.ai.search_id
    subresource_names              = ["searchService"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "search-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.search.id]
  }
}

resource "azurerm_private_endpoint" "storage" {
  count               = var.enable_vnet_integration ? 1 : 0
  name                = "${local.st_name}-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${local.st_name}-psc"
    private_connection_resource_id = module.storage.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

# Shared private links — the private path the AI Search *service* uses to reach OpenAI (embedding
# skill) and Storage (indexer blob reads) once those backends stop accepting public traffic. Unlike
# a private endpoint (which gives the App Service a private inbound path), a shared private link is
# owned by the Search service and originates from inside its managed network. Only created with VNet
# integration on; the free config keeps everything public.
resource "azurerm_search_shared_private_link_service" "openai" {
  count              = var.enable_vnet_integration ? 1 : 0
  name               = "${local.srch_name}-spl-openai"
  search_service_id  = module.ai.search_id
  subresource_name   = "openai_account"
  target_resource_id = module.ai.openai_id
  request_message    = "Aria AI Search embedding skill"
}

resource "azurerm_search_shared_private_link_service" "blob" {
  count              = var.enable_vnet_integration ? 1 : 0
  name               = "${local.srch_name}-spl-blob"
  search_service_id  = module.ai.search_id
  subresource_name   = "blob"
  target_resource_id = module.storage.id
  request_message    = "Aria AI Search indexer blob access"
}

# A shared private link lands as a Pending private endpoint connection on the target and must be
# approved on the target side. There is no first-class azurerm resource to approve a Search-owned
# shared-private-link connection, so approve via the Azure CLI — the same local-exec/az pattern the
# Search data plane already uses. Retry briefly because the connection appears asynchronously.
resource "terraform_data" "approve_shared_private_links" {
  count = var.enable_vnet_integration ? 1 : 0

  triggers_replace = [
    azurerm_search_shared_private_link_service.openai[0].id,
    azurerm_search_shared_private_link_service.blob[0].id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      approve_pending() {
        local target_id="$1"
        for attempt in $(seq 1 12); do
          ids=$(az network private-endpoint-connection list --id "$target_id" \
            --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].id" -o tsv)
          if [ -n "$ids" ]; then
            for id in $ids; do
              az network private-endpoint-connection approve --id "$id" \
                --description "Approved by Terraform (Aria shared private link)" >/dev/null
            done
            return 0
          fi
          sleep 10
        done
        echo "No pending shared-private-link connection found on $target_id after retries" >&2
        return 1
      }
      approve_pending "${module.ai.openai_id}"
      approve_pending "${module.storage.id}"
    EOT
  }

  depends_on = [
    azurerm_search_shared_private_link_service.openai,
    azurerm_search_shared_private_link_service.blob,
  ]
}
