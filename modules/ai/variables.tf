variable "openai_name" {
  type = string
}

variable "search_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "openai_model" {
  type = string
}

variable "openai_model_version" {
  type = string
}

variable "openai_capacity" {
  type = number
}

variable "embedding_model" {
  type = string
}

variable "embedding_capacity" {
  type    = number
  default = 10
}

variable "search_sku" {
  description = "AI Search SKU: free, basic, standard, ..."
  type        = string
}

variable "search_replica_count" {
  type    = number
  default = 1
}

variable "search_partition_count" {
  type    = number
  default = 1
}

variable "search_local_auth_enabled" {
  description = "Whether API keys are usable on AI Search. The free tier cannot disable local auth."
  type        = bool
  default     = false
}

variable "search_identity_enabled" {
  description = "Whether the search service gets a system-assigned managed identity (Basic tier or higher only)."
  type        = bool
  default     = true
}

variable "search_public_network_access" {
  type    = bool
  default = true
}

variable "openai_public_network_access" {
  description = "Whether the Azure OpenAI account is reachable over its public endpoint. Set false for a private posture; App Service then reaches it via a private endpoint and the AI Search indexer via a shared private link."
  type        = bool
  default     = true
}

variable "search_allowed_ips" {
  type    = list(string)
  default = []
}

variable "semantic_search_sku" {
  description = "Semantic ranker SKU (e.g. \"free\"). Null disables semantic search (required on the free search tier)."
  type        = string
  default     = null
}
