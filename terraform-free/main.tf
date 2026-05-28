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
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

provider "azuread" {}

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
      exit 0
    EOT
  }

  depends_on = [azurerm_resource_group.main]
}
