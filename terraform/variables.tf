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

# ============================================================
# SKU CONFIGURATION
# ============================================================

variable "app_service_sku" {
  description = "App Service Plan SKU. Default: P1v3 (~$130/mo). VNet integration requires a Basic-tier SKU or higher (P1v3 recommended for production)."
  default     = "P1v3"
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
  description = "OpenAI deployment capacity in thousands of tokens per minute. Increase for higher concurrent load."
  default     = 10
}

variable "embedding_model" {
  description = "Azure OpenAI embedding model deployment name. Index vector dimensions are derived from this automatically (see locals.tf)."
  default     = "text-embedding-3-small"

  validation {
    condition     = contains(["text-embedding-3-small", "text-embedding-3-large", "text-embedding-ada-002"], var.embedding_model)
    error_message = "embedding_model must be one of: text-embedding-3-small, text-embedding-3-large, text-embedding-ada-002."
  }
}

variable "enable_vnet_integration" {
  description = "Enables the private network posture: App Service VNet integration (outbound), private endpoints for all backends, OpenAI public access disabled, and Search/Storage firewalled to the deployer IP. Only the App Service stays reachable from the internet. Requires a Basic-tier or higher App Service SKU (P1v3 recommended). Set false only for a cheaper all-public test in this folder."
  default     = true
}

variable "company_name" {
  description = "Company name shown in the Aria chat UI header and empty state."
  default     = "Contoso"
}

# ============================================================
# TOPICS & ACCESS MODEL
# ============================================================

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
      "all_users"     — any authenticated employee (default; topics are discoverable company-wide)
      "role_required" — strict least privilege; even base-tier docs require a <topic>.<BaseTier>.Read
                        role, and topics are invisible to users holding no role for them.
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

# ============================================================
# AI SEARCH CAPACITY (cost-sensitive — see README)
# Azure AI Search billing = replicas x partitions. Each extra
# replica/partition roughly adds one unit of the SKU base cost.
# ============================================================

variable "search_replica_count" {
  description = "AI Search replicas. Use 2+ for a query SLA / HA, 3 for read-write SLA. Each replica increases Search cost."
  default     = 1

  validation {
    condition     = var.search_replica_count >= 1 && var.search_replica_count <= 12
    error_message = "search_replica_count must be between 1 and 12."
  }
}

variable "search_partition_count" {
  description = "AI Search partitions. Increase for larger indexes or higher indexing/query throughput. Partitions multiply Search cost."
  default     = 1

  validation {
    condition     = contains([1, 2, 3, 4, 6, 12], var.search_partition_count)
    error_message = "search_partition_count must be one of: 1, 2, 3, 4, 6, 12."
  }
}

# ============================================================
# MONITORING
# ============================================================

variable "alert_email" {
  description = "Email address to receive metric alert notifications. Leave empty to create alerts without a notification target."
  default     = ""
}
