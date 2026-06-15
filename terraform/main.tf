terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

provider "azuread" {}

# Used to detect the public IP of the machine running terraform apply.
# The IP is added to the AI Search firewall when VNet integration is enabled,
# so data plane resources (index, indexers, etc.) can be managed without a VNet-connected runner.
data "http" "my_ip" {
  url = "https://api.ipify.org"
}

data "azuread_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = local.rg_name
  location = var.location
}

# Deletes any alert rules not managed by Terraform before the resource group is destroyed.
# Azure auto-creates metric alerts (and Defender for Cloud alerts) that block RG deletion.
resource "terraform_data" "cleanup_alerts" {
  input = azurerm_resource_group.main.name

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set +e
      RG="${self.output}"
      for type in "microsoft.insights/metricalerts" "microsoft.insights/activitylogalerts" "microsoft.insights/scheduledqueryrules"; do
        ids=$(az resource list --resource-group "$RG" --resource-type "$type" --query "[].id" -o tsv 2>/dev/null)
        [ -n "$ids" ] && echo "$ids" | xargs az resource delete --ids 2>/dev/null
      done
      # Smart-detector alert rules (auto-created with Application Insights) are not returned by
      # `az resource list`, so query and delete them via the alerts-management API — otherwise they
      # block resource group deletion.
      SUB=$(az account show --query id -o tsv 2>/dev/null)
      sd_ids=$(az rest --method get --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/microsoft.alertsmanagement/smartDetectorAlertRules?api-version=2021-04-01" --query "value[].id" -o tsv 2>/dev/null)
      for id in $sd_ids; do
        az rest --method delete --url "https://management.azure.com$id?api-version=2021-04-01" 2>/dev/null
      done
      exit 0
    EOT
  }

  depends_on = [azurerm_resource_group.main]
}
