# Changelog

All notable changes to Aria are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Adopter upgrade path: `git pull` then `terraform apply`. Changes marked **breaking** that
recreate the search data plane are safe — blob storage is the source of truth and the indexer
rebuilds the index from blobs.

## [Unreleased]

### Added
- **Topics**: department-scoped chatbots (e.g. HR, IT) over one shared infrastructure stack,
  driven by the `topics` Terraform variable. Adding a topic is one map entry plus `terraform apply`.
- **Configurable access tiers** via the `tiers` variable (ordered list, default
  `["general", "internal"]`). Each tier above the base generates a `<Tier>.Read` role; the
  hierarchy in `app/access.py` is now tier-agnostic. Use `["general"]` for topic-membership-only
  access or add `"confidential"` for a third level. (The base tier was renamed `public` → `general`
  to avoid implying unauthenticated access — everything is behind Entra login.)
- **Auto-provisioned role groups**: with `create_role_groups = true` (default), Terraform creates
  one Entra security group per app role and binds it, so admins manage access by group membership
  only — the role propagates into each member's token automatically. Requires Entra ID P1+. The
  `role_groups` output maps each role to its group name and object id.
- **Two-dimensional access control**: server-side search filter `topic eq X and access_level in (...)`
  derived purely from the user's Entra app roles. A role for topic A can never retrieve topic B
  content. Logic lives in `app/access.py` and is covered by regression tests (`tests/test_access.py`).
- **Generated per-topic app roles** (`<topic>.Internal.Read`, `<topic>.Confidential.Read`,
  `<topic>.Content.Admin`, plus `<topic>.Public.Read` in `role_required` mode).
- **`public_tier_mode`** variable: `all_users` (public docs visible to any employee) or
  `role_required` (strict least privilege — topics invisible without a role).
- **Landing page** (`/`) with cards for the topics the user can access; auto-redirects when the
  user can access exactly one topic.
- **Document manager** (`/admin`) for `Content.Admin` holders: per-tier file list, upload, soft
  delete (via `IsDeleted` blob metadata), and on-demand reindex — all enforced server-side per topic.
- MIT `LICENSE` and this changelog.

### Changed
- **Search data plane** rewritten to a single datasource + single indexer over the whole
  documents container, with `topic` and `access_level` carried as blob metadata. New topics need
  no indexer changes. **(breaking: recreates the search data plane)**
- Terraform refactored into shared `modules/` (ai, app, identity, storage, search_dataplane);
  `terraform/` (secure baseline) and `terraform-free/` (low-cost trial) are thin roots.
- Sample documents restructured to `sample-docs/<topic>/<access_level>/`, with public-tier samples
  in every topic so a fresh deploy demonstrates multi-topic isolation before any role assignment.
- **Secretless Easy Auth** in both roots: App Service built-in auth authenticates to Entra ID with a
  federated identity credential backed by a dedicated user-assigned managed identity, so no client
  secret is created or stored. Removes the plaintext auth secret from the free tier and removes Key
  Vault from the secure baseline entirely. Toggle via `use_managed_identity_auth` on the identity
  module (workforce tenants only). The app's system-assigned identity still carries data-plane RBAC.
- Added diagnostics to Log Analytics and metric alerts (App Service 5xx/latency, Search throttling,
  OpenAI errors).

### Security
- Chunk-level retrieval (SplitSkill + per-chunk embedding + index projections) replaces
  whole-document embedding, improving retrieval quality and ACL enforcement granularity.
- AI Search and Storage local/key auth disabled in the secure baseline; access via managed identity.
