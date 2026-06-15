variable "name" {
  description = "Display name of the Entra ID app registration"
  type        = string
}

variable "app_url" {
  description = "Base URL of the web app (used for redirect URIs)"
  type        = string
}

variable "topics" {
  description = "Map of topic slug => display name. Drives per-topic app role generation."
  type        = map(string)
}

variable "tiers" {
  description = <<-EOT
    Ordered list of access tiers, most-open first. tiers[0] is the open/base tier (e.g. "public").
    Each higher tier gets a generated "<Tier>.Read" role granting that tier and every tier below it.
  EOT
  type        = list(string)
}

variable "public_tier_mode" {
  description = "\"all_users\" or \"role_required\". In role_required mode the base tier also gets a generated <topic>.<BaseTier>.Read role."
  type        = string
}

variable "create_role_groups" {
  description = <<-EOT
    When true, create one Entra security group per generated app role and assign the group to that
    role. Admins then manage access by group membership only. Requires Entra ID P1 or higher
    (group-based app role assignment is a premium feature).
  EOT
  type        = bool
  default     = false
}

variable "require_role_assignment" {
  description = "When true, only users with an explicit app role assignment can authenticate."
  type        = bool
  default     = true
}

variable "secret_rotation_days" {
  description = "Rotation interval (days) for the Easy Auth client secret. Ignored when use_managed_identity_auth = true."
  type        = number
  default     = 180
}

variable "use_managed_identity_auth" {
  description = <<-EOT
    When true, Easy Auth authenticates to Entra ID with a federated identity credential backed by a
    user-assigned managed identity instead of a client secret — no secret is created or stored.
    Requires easy_auth_fic_subject and tenant_id. Workforce tenants only.
  EOT
  type        = bool
  default     = false
}

variable "easy_auth_fic_subject" {
  description = "Principal (object) ID of the user-assigned managed identity trusted as the Easy Auth FIC subject. Required when use_managed_identity_auth = true."
  type        = string
  default     = null
}

variable "tenant_id" {
  description = "Entra tenant ID, used to build the FIC issuer URL. Required when use_managed_identity_auth = true."
  type        = string
  default     = null
}
