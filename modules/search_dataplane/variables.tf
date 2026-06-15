variable "search_name" {
  type = string
}

variable "container_name" {
  type = string
}

variable "datasource_connection_string" {
  description = "Blob connection for the indexer: \"ResourceId=...\" (managed identity) or a full connection string (account key, free tier)."
  type        = string
  sensitive   = true
}

variable "admin_api_key" {
  description = "AI Search admin key. Empty uses Entra ID auth via az rest (requires local auth disabled on the service to be meaningful)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "openai_endpoint" {
  type = string
}

variable "openai_api_key" {
  description = "OpenAI key for the embedding skill. Empty uses the search service's managed identity."
  type        = string
  sensitive   = true
  default     = ""
}

variable "embedding_deployment" {
  type = string
}

variable "embedding_model" {
  type = string
}

variable "embedding_dimensions" {
  type = number
}

variable "semantic_enabled" {
  description = "Adds a semantic configuration to the index. Requires semantic search enabled on the service."
  type        = bool
  default     = false
}

variable "chunk_max_chars" {
  description = "Chunk size in characters (~4 chars per token)."
  type        = number
  default     = 2000
}

variable "chunk_overlap_chars" {
  type    = number
  default = 200
}
