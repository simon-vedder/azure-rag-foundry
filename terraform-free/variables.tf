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

variable "openai_model" {
  description = "Azure OpenAI chat model. Do not use gpt-4o-mini (retired March 31 2026) or gpt-4o versions 2024-05-13/2024-08-06 (also retired)."
  default     = "gpt-4o"
}

variable "openai_model_version" {
  description = "Azure OpenAI chat model version. 2024-11-20 is current stable (retires Oct 1 2026)."
  default     = "2024-11-20"
}

variable "openai_capacity" {
  description = "OpenAI deployment capacity in thousands of tokens per minute."
  default     = 10
}

variable "embedding_model" {
  description = "Azure OpenAI embedding model deployment name. Do not change without also updating index dimensions in search_dataplane.tf."
  default     = "text-embedding-3-small"
}

variable "company_name" {
  description = "Company name shown in the Aria chat UI header and empty state."
  default     = "Contoso"
}
