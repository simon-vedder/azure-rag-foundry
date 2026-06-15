# terraform-free is the low-cost trial/demo variant: free AI Search tier, key-based auth, public
# endpoints, B1 App Service. It runs the same app and topic model as terraform/ (the secure
# baseline) by composing the same shared modules — only the SKUs and auth wiring differ.
# See the security disclaimer in the README before putting sensitive documents here.

variable "subscription_id" {
  description = "Azure Subscription ID"
}

variable "prefix" {
  description = "Short prefix for all resource names (2-6 lowercase alphanumeric chars)"
  default     = "rag"

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.prefix))
    error_message = "prefix must be 2-6 lowercase alphanumeric characters."
  }
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
  description = "Azure OpenAI embedding model deployment name. Index vector dimensions are derived automatically (see modules/ai)."
  default     = "text-embedding-3-small"

  validation {
    condition     = contains(["text-embedding-3-small", "text-embedding-3-large", "text-embedding-ada-002"], var.embedding_model)
    error_message = "embedding_model must be one of: text-embedding-3-small, text-embedding-3-large, text-embedding-ada-002."
  }
}

variable "company_name" {
  description = "Company name shown in the Aria chat UI header and empty state."
  default     = "Contoso"
}

variable "topics" {
  description = <<-EOT
    Topics (department chatbots) as a map of URL slug => display name.
    Each topic gets its own document folder, generated Entra app roles, landing page card,
    and chat page at /t/<slug>. Adding a topic is one entry here + terraform apply.
  EOT
  type        = map(string)
  default     = { hr = "HR", it = "IT" }

  validation {
    condition = length(var.topics) > 0 && alltrue([
      for slug, display in var.topics : can(regex("^[a-z0-9]{2,24}$", slug)) && length(display) > 0
    ])
    error_message = "Topic slugs must be 2-24 lowercase alphanumeric characters; display names must be non-empty."
  }
}

variable "public_tier_mode" {
  description = <<-EOT
    Who can see a topic's base-tier (tiers[0], e.g. "general") documents:
      "all_users"     — any authenticated employee (default).
      "role_required" — even base-tier docs require a <topic>.<BaseTier>.Read role.
  EOT
  default     = "all_users"

  validation {
    condition     = contains(["all_users", "role_required"], var.public_tier_mode)
    error_message = "public_tier_mode must be \"all_users\" or \"role_required\"."
  }
}

variable "tiers" {
  description = <<-EOT
    Ordered list of access tiers per topic, most-open first. tiers[0] is the open/base tier.
    Each higher tier gets a generated "<Tier>.Read" app role granting that tier and every tier
    below it. Default is two tiers (general + internal); use ["general"] for topic-membership-only
    access, or add "confidential" for a third sensitivity level.
  EOT
  type        = list(string)
  default     = ["general", "internal"]

  validation {
    condition = length(var.tiers) >= 1 && length(var.tiers) == length(distinct(var.tiers)) && alltrue([
      for t in var.tiers : can(regex("^[a-z][a-z0-9]*$", t))
    ])
    error_message = "tiers must be a non-empty list of unique, lowercase single-word names (e.g. [\"public\", \"internal\"])."
  }
}

variable "create_role_groups" {
  description = <<-EOT
    Create one Entra security group per generated app role and assign the group to that role, so
    admins manage access by group membership only. Requires Entra ID P1+ (group-based app role
    assignment is a premium feature).
  EOT
  type        = bool
  default     = true
}
