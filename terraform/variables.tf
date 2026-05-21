variable "subscription_id" {
  description = "Azure Subscription ID"
}

variable "prefix" {
  description = "Short prefix for all resource names (2-6 lowercase alphanumeric chars)"
  default     = "rag"
}

variable "location" {
  description = "Azure region"
  default     = "swedencentral"
}

# ============================================================
# SKU CONFIGURATION
# Change the values below to upgrade from test to production.
# ============================================================

variable "app_service_sku" {
  description = "App Service Plan SKU. Test: B1 (~$13/mo). Prod: P1v3 (~$150/mo)."
  default     = "B1" # PROD UPGRADE: change to "P1v3"
}

variable "openai_model" {
  description = "Azure OpenAI chat model deployment name. Test: gpt-4o (2024-11-20). Prod: gpt-4o (2024-11-20) with higher capacity."
  default     = "gpt-4o"
}

variable "openai_model_version" {
  description = "Azure OpenAI chat model version."
  default     = "2024-11-20"
}

variable "openai_capacity" {
  description = "OpenAI deployment capacity in thousands of tokens per minute."
  default     = 10 # PROD UPGRADE: increase as needed
}

variable "search_sku" {
  description = "Azure AI Search SKU. Test: free ($0). Prod: standard (~$250/mo)."
  default     = "free" # PROD UPGRADE: change to "standard"
}

variable "enable_vnet_integration" {
  description = "Enable App Service VNet integration and private endpoints. Requires P1v3+."
  default     = false # PROD UPGRADE: change to true (also set app_service_sku to "P1v3")
}

variable "company_name" {
  description = "Company name shown in the Aria chat UI header and empty state."
  default     = "Contoso"
}
