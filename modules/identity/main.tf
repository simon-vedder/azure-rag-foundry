terraform {
  required_providers {
    azuread = {
      source = "hashicorp/azuread"
    }
    random = {
      source = "hashicorp/random"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

# Per-topic app roles, generated from the topics and tiers variables.
# Role values follow the pattern <topic-slug>.<Tier>.<Action> and are parsed by the app
# (app/access.py) to build the server-side search filter — the role value is the contract.
locals {
  base_tier = var.tiers[0] # most-open tier, e.g. "public"

  # Each tier above the base gets a Reader role that grants that tier and every tier below it.
  reader_roles = {
    for tier in slice(var.tiers, 1, length(var.tiers)) :
    "${title(tier)}.Read" => {
      title       = "${title(tier)} Reader"
      description = "Can read ${tier}-level documents (and every less-sensitive tier)"
    }
  }

  admin_role = {
    "Content.Admin" = { title = "Content Admin", description = "Can manage documents (upload, delete, reindex) and read every tier" }
  }

  # In role_required mode even the base tier needs an explicit role; topics without any assigned
  # role are then invisible to the user.
  base_role = var.public_tier_mode == "role_required" ? {
    "${title(local.base_tier)}.Read" = { title = "${title(local.base_tier)} Reader", description = "Can read ${local.base_tier}-level documents" }
  } : {}

  role_defs = merge(local.reader_roles, local.admin_role, local.base_role)

  app_roles = merge([
    for slug, display in var.topics : {
      for value, meta in local.role_defs :
      "${slug}.${value}" => {
        display_name = "${display} ${meta.title}"
        description  = "${meta.description} in the ${display} topic."
      }
    }
  ]...)
}

resource "random_uuid" "role" {
  for_each = local.app_roles
}

resource "azuread_application" "main" {
  display_name     = var.name
  sign_in_audience = "AzureADMyOrg"

  dynamic "app_role" {
    for_each = local.app_roles
    iterator = role
    content {
      allowed_member_types = ["User"]
      id                   = random_uuid.role[role.key].result
      value                = role.key
      display_name         = role.value.display_name
      description          = role.value.description
      enabled              = true
    }
  }

  web {
    homepage_url  = var.app_url
    redirect_uris = ["${var.app_url}/.auth/login/aad/callback"]

    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = true
    }
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph

    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "main" {
  client_id                    = azuread_application.main.client_id
  app_role_assignment_required = var.require_role_assignment
}

# Easy Auth credential.
# App Service built-in auth (Easy Auth) acts as a confidential OIDC client. It authenticates to
# Entra ID in one of two ways, selected by use_managed_identity_auth:
#   - false: a client secret (created here, rotated on a schedule). The root decides how it is
#            stored (Key Vault reference vs plain app setting).
#   - true:  a federated identity credential (FIC) that trusts a user-assigned managed identity, so
#            no secret exists at all — Easy Auth presents the MI token as the client assertion. The
#            root wires the MI's client id into OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID (see compute.tf).
resource "time_rotating" "easy_auth_secret" {
  count         = var.use_managed_identity_auth ? 0 : 1
  rotation_days = var.secret_rotation_days
}

resource "azuread_application_password" "easy_auth" {
  count          = var.use_managed_identity_auth ? 0 : 1
  application_id = azuread_application.main.id
  display_name   = "easy-auth"
  # Valid for the rotation window plus a 30-day grace buffer so the old secret never expires
  # before Terraform recreates it on the next rotation.
  end_date = timeadd(time_rotating.easy_auth_secret[0].rotation_rfc3339, "720h")

  rotate_when_changed = {
    rotation = time_rotating.easy_auth_secret[0].id
  }
}

# Secretless alternative: trust a user-assigned managed identity so Easy Auth needs no client secret.
# The subject must be the MI's principal (object) ID; the audience is the fixed token-exchange value.
# Workforce tenants only (not supported for external/B2C configurations).
resource "azuread_application_federated_identity_credential" "easy_auth" {
  count = var.use_managed_identity_auth ? 1 : 0

  application_id = azuread_application.main.id
  display_name   = "easy-auth-mi"
  description    = "Lets App Service Easy Auth authenticate as this app via a managed identity instead of a secret."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
  subject        = var.easy_auth_fic_subject
}

# Optional: one Entra security group per app role, assigned to that role. Admins manage access
# purely by adding members to these groups — the app role (and therefore the search filter) is
# emitted into each member's token automatically, so no app changes are needed.
# Group-based app role assignment requires Entra ID P1+ (see create_role_groups).
resource "azuread_group" "role" {
  for_each = var.create_role_groups ? local.app_roles : {}

  display_name     = "Aria - ${each.value.display_name} - ${var.name}"
  description      = each.value.description
  security_enabled = true
}

resource "azuread_app_role_assignment" "group" {
  for_each = var.create_role_groups ? local.app_roles : {}

  app_role_id         = random_uuid.role[each.key].result
  principal_object_id = azuread_group.role[each.key].object_id
  resource_object_id  = azuread_service_principal.main.object_id
}
