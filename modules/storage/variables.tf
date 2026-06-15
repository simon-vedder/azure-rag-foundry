variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "network_rules_enabled" {
  type    = bool
  default = false
}

variable "allowed_ips" {
  type    = list(string)
  default = []
}

variable "topics" {
  description = "Map of topic slug => display name. Sample docs are only uploaded for configured topics."
  type        = map(string)
}

variable "tiers" {
  description = "Configured access tiers. Sample docs in folders outside this set are skipped."
  type        = list(string)
  default     = ["public", "internal", "confidential"]
}

variable "sample_docs_path" {
  description = "Path to a sample-docs directory laid out as <topic>/<access_level>/<file>. Empty disables sample uploads."
  type        = string
  default     = ""
}
