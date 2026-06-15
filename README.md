# Azure RAG Foundry — Aria

**Aria** is a ready-to-deploy enterprise RAG chatbot built on Azure. Employees authenticate with their company's Entra ID account and ask questions against internal documents in natural language. Answers stream back in real time, grounded in the documents — not hallucinated.

Access is role-based: users only see documents they're authorized for.

Two Terraform configs are included:

| Config | Tier | Cost | Use case |
|---|---|---|---|
| `terraform/` | Standard | ~$416/month | Production — MSI everywhere, no secrets (secretless Easy Auth), VNet-ready |
| `terraform-free/` | Free | ~$15/month | Testing/demos — API keys, no VNet, fully functional |

---

## Contents

- [What you get](#what-you-get)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quickstart](#quickstart)
  - [1. Login](#1-login)
  - [2. Check free AI Search quota](#2-check-free-ai-search-quota-free-config-only)
  - [3. Configure Terraform](#3-configure-terraform)
  - [4. Deploy infrastructure and app](#4-deploy-infrastructure-and-app)
  - [5. Grant admin consent](#5-grant-admin-consent-entra-admin-required)
  - [6. Assign app roles to users](#6-assign-app-roles-to-users)
  - [7. Upload documents](#7-upload-documents)
  - [8. Open the app](#8-open-the-app)
- [Adding a Department (Topic)](#adding-a-department-topic)
- [Managing the Knowledge Base](#managing-the-knowledge-base)
  - [Adding or updating documents](#adding-or-updating-documents)
  - [Deleting documents](#deleting-documents)
  - [Changing a document's access level](#changing-a-documents-access-level)
- [Company Branding](#company-branding)
- [Going to Production](#going-to-production)
- [Cost Estimate](#cost-estimate)
- [Variables Reference](#variables-reference)
- [File Structure](#file-structure)
- [Before Going Live in Production](#before-going-live-in-production)
  - [Security](#security)
  - [Data & Compliance](#data--compliance)
  - [Reliability & Capacity](#reliability--capacity)
  - [Monitoring & Cost](#monitoring--cost)
  - [Ongoing Operations](#ongoing-operations)
- [Production Recommendations](#production-recommendations)
- [Destroying](#destroying)
- [Quick Deploy — All Commands](#quick-deploy--all-commands)

---

## What you get

- **Chat UI** — clean, modern interface (Aria branding, customizable per company)
- **Streamed responses** — tokens appear as they're generated, not after a full round-trip
- **Chunked retrieval** — documents are split into overlapping chunks and embedded per chunk for better recall and cleaner citations (not whole-file embedding)
- **Hybrid search** — vector + keyword search across your documents (AI Search)
- **Role-based document access** — configurable sensitivity tiers (default `general`, `internal`) enforced server-side
- **Entra ID auth** — Easy Auth blocks unauthenticated users before they reach your app
- **Zero secrets in the secure baseline** — App Service Managed Identity accesses OpenAI, Search, and Storage via RBAC, and Easy Auth itself is secretless (a federated identity credential replaces the client secret)
- **Diagnostics & alerts** — platform logs/metrics flow to Log Analytics, with metric alerts on errors, latency, and throttling
- **Markdown rendering** — AI responses render with formatting (headers, lists, code blocks)
- **Conversation history** — last 10 turns sent with each request for context
- **Company branding** — set your company name via a Terraform variable

---

## Architecture

```
Browser
  │  (Entra ID Easy Auth — blocks unauthenticated requests)
  ▼
App Service — FastAPI (Python 3.12)
  ├── /          → chat UI (index.html)
  ├── /chat      → SSE streaming: embed → search → GPT-4o stream
  ├── /branding  → company name + logo URL from App Settings
  └── /health    → liveness check

App Service Managed Identity (RBAC, no keys)
  ├── Azure OpenAI     — GPT-4o (chat) + text-embedding-3-small
  ├── Azure AI Search  — hybrid vector + keyword, role-filtered
  └── Blob Storage     — document source (documents/ container)
```

**Test mode (default):** App Service reaches backend services over public endpoints using RBAC. No VNet needed.  
**Production mode:** Private endpoints + VNet integration lock down all backend traffic. Flip three variables.

---

## Prerequisites

- Azure subscription with **Azure OpenAI access approved** ([request here](https://aka.ms/oai/access) — approval can take 1–2 days)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.9
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)

---

## Quickstart

Pick the config that fits your situation:
- **`terraform-free/`** — free AI Search, B1 App Service, API keys. Start here to try the app.
- **`terraform/`** — standard AI Search, P1v3 App Service, Managed Identity everywhere. Use for production.

The steps below apply to both. Replace `terraform/` with `terraform-free/` if you're using the free config.

### 1. Login

```bash
az login
az account set --subscription "<your-subscription-id>"
```

### 2. Check free AI Search quota (free config only)

Only one free-tier AI Search service is allowed per subscription:

```bash
az search service list --query "[?sku.name=='free'].{name:name, rg:resourceGroup}" -o table
```

If one already exists, use the standard `terraform/` config instead.

### 3. Configure Terraform

Create `terraform-free/terraform.tfvars` (or `terraform/terraform.tfvars` for prod):

```hcl
subscription_id = "<your-subscription-id>"
company_name    = "Acme Corp"           # shown in the Aria UI
```

All other variables have sensible defaults. See [variables reference](#variables-reference) for the full list.

### 4. Deploy infrastructure and app

```bash
cd terraform-free    # or: cd terraform
terraform init
terraform apply
```

This takes 5–10 minutes. Terraform creates all infrastructure and deploys the app in one step — it zips `app/` automatically and deploys it to App Service via `zip_deploy_file`.

### 5. Grant admin consent (Entra admin required)

The App Registration requests `User.Read` from Microsoft Graph. An Entra admin must grant tenant-wide consent:

```bash
CLIENT_ID=$(terraform -chdir=terraform-free output -raw entra_app_client_id)
# or: terraform -chdir=terraform output -raw entra_app_client_id
az ad app permission admin-consent --id "$CLIENT_ID"
```

Or in the portal: **Entra ID → App registrations → `rag-auth-<suffix>` → API permissions → Grant admin consent**.

### 6. Give users access

Each topic gets its own set of generated app roles, one per configured tier plus a content admin.
With the default `tiers = ["general", "internal"]`, a topic with display name `HR` produces:

| Role (portal display) | Role value | Access in that topic |
|---|---|---|
| *(any authenticated user)* | — | `general` tier (only in `public_tier_mode = all_users`, the default) |
| `HR Internal Reader` | `hr.Internal.Read` | `general` + `internal` |
| `HR Content Admin` | `hr.Content.Admin` | read all tiers **and** manage documents (`/admin`) |

Add `"confidential"` to `tiers` and you also get `HR Confidential Reader` (`hr.Confidential.Read`).
Roles are strictly per topic — `hr.Internal.Read` grants nothing in `it`. In
`public_tier_mode = role_required`, even the base tier needs an explicit `hr.General.Read` role and
topics are invisible to users holding no role for them.

**Recommended: manage access by group (default).** With `create_role_groups = true` (the default,
requires Entra ID P1+), Terraform creates one security group per role and assigns it, so you never
touch app-role assignments — you just add people to groups:

```bash
terraform -chdir=terraform output role_groups   # role value -> { group name, object id }
# Add a user to the "HR Internal Reader" group → they get hr.Internal.Read on next sign-in.
az ad group member add --group "<group object id>" --member-id "<user object id>"
```

The app role lands in the member's token automatically, so the search filter just works. (Only
direct group members get the role — nested groups aren't honored.)

**Manual alternative.** Set `create_role_groups = false` and assign roles directly:
**Entra ID → Enterprise applications → `rag-auth-<suffix>` → Users and groups → Add user/group**.

### 7. Upload your own documents (optional)

Sample documents are already in place from the `terraform apply` in step 4 — you can start chatting as
soon as steps 5 and 6 are done.

The easiest way to load your own content is the built-in **document manager at `/admin`** (any
`*.Content.Admin` holder), covered in [Managing the Knowledge Base](#managing-the-knowledge-base).

To bulk-load from the CLI instead, documents live under `<topic>/<access_level>/` in the `documents`
blob container, and the `topic` + `access_level` blob metadata is the authoritative source for the
index (the folder path is convention for humans):

```
documents/
  hr/general/        it/general/        → general tier (all authenticated users)
  hr/internal/       it/internal/       → Internal Reader role required
  hr/confidential/   it/confidential/   → Confidential Reader role (only if "confidential" is a configured tier)
```

```bash
STORAGE=$(terraform -chdir=terraform output -raw storage_account_name)

az storage blob upload \
  --account-name "$STORAGE" \
  --container-name documents \
  --name "hr/general/q1-2026-report.pdf" \
  --file ./q1-2026-report.pdf \
  --metadata topic=hr access_level=general \
  --auth-mode login
```

> **The `topic` and `access_level` metadata are required.** A blob without them matches no access
> filter and is invisible to every user (fail closed).

Supported formats: **PDF, DOCX, TXT, MD, CSV**. The AI Search indexer picks up new files automatically
every hour, or trigger it immediately with the **Reindex now** button in `/admin`.

> **Permissions:** CLI upload requires `Storage Blob Data Contributor` on the storage account. Assign it
> once: `az role assignment create --role "Storage Blob Data Contributor" --assignee "<your-object-id>" --scope "<storage-account-id>"`

### 8. Open the app

```bash
terraform -chdir=terraform-free output -raw app_url
# or: terraform -chdir=terraform output -raw app_url
```

The landing page (`/`) shows a card for each topic you can access. Pick one to chat; if you can access
exactly one topic you're taken straight into it.

---

## Adding a Department (Topic)

A "department" is a **topic** — a department-scoped chatbot over the shared infrastructure. Each topic
gets its own document folder, generated Entra app roles and access groups, landing-page card, chat page
at `/t/<slug>`, and AI Search filter scoping. A role for one topic can **never** retrieve another topic's
content — that isolation is the security boundary, enforced in `build_search_filter` (`app/access.py`).

The `topics` map in `terraform.tfvars` is the single source of truth. Adding a department is one entry
plus `terraform apply` — no application code changes.

**1. Add the topic** — a `slug => display name` entry in `terraform/terraform.tfvars` (or `terraform-free/`):

```hcl
topics = {
  hr      = "HR"
  it      = "IT"
  finance = "Finance"   # ← new department
}
```

Slug rules: 2–24 lowercase alphanumeric characters. The slug becomes the URL (`/t/finance`), the blob
folder, and the role prefix (`finance.Internal.Read`, `finance.Content.Admin`, …).

**2. Apply** — `terraform -chdir=terraform apply`. A single apply:

- mints the Entra app roles for the new topic across every configured tier
  (`finance.General.Read`, `finance.Internal.Read`, `finance.Content.Admin`)
- creates the auto-provisioned Entra **access groups** so you assign people to a group, not individually
  (requires Entra ID P1+; see [Going to Production](#going-to-production))
- adds the landing-page card and the `/t/finance` chat page
- updates the `TOPICS` app setting; the server picks it up with no redeploy

**3. Grant admin consent again** — new app roles require re-consent. Re-run the
[Grant admin consent](#5-grant-admin-consent-entra-admin-required) step.

**4. Add documents** — blob layout is `<slug>/<tier>/<file>`, with `topic` and `access_level` metadata
(the metadata is what the indexer projects into the index). Either seed them through Terraform by dropping
files in `sample-docs/finance/general/…` (uploaded on apply), or use the in-app
[document manager](#option-a--the-built-in-document-manager-recommended) once a user holds
`finance.Content.Admin`.

**5. Assign users** — Entra ID → Enterprise applications → `rag-auth-<suffix>` → **Users and groups** →
add people to the generated `finance` group for the tier they need. Base-tier (`general`) visibility
depends on `public_tier_mode`: the default `all_users` lets every authenticated employee see `general`
docs without a role; `role_required` hides the topic entirely until a role is assigned.

> **Tiers** are the sensitivity axis, configured separately via the `tiers` variable (default
> `["general", "internal"]`, most-open first). The `sample-docs/` tree also ships `confidential/`
> folders — to activate that third tier, set `tiers = ["general", "internal", "confidential"]`, otherwise
> files under unconfigured tiers are skipped on upload.

---

## Managing the Knowledge Base

Ingestion is fully automated. The single AI Search indexer runs every hour over the whole `documents`
container and picks up new, modified, and deleted files automatically. There are two ways to manage
documents.

### Option A — the built-in document manager (recommended)

Open `/admin` as a user holding a `*.Content.Admin` role. For each topic you administer you can:

- See the current documents grouped by access tier.
- **Upload** a file — pick the topic and access level; the blob path and `topic`/`access_level`
  metadata are written for you, scoped to your topic.
- **Delete** a file — sets the `IsDeleted` soft-delete metadata so the indexer drops its chunks.
- **Reindex now** — triggers the indexer instead of waiting up to an hour.

An admin can only ever act on topics they hold `Content.Admin` for; the server builds every blob path
from the validated topic, so an HR admin cannot write into `it/`.

### Option B — the Azure CLI

The metadata is what counts; the folder path is just convention. Always set `topic` and `access_level`.

```bash
STORAGE=$(terraform -chdir=terraform output -raw storage_account_name)

# Add or update a document
az storage blob upload \
  --account-name "$STORAGE" --container-name documents \
  --name "hr/internal/salary-bands-2026.pdf" \
  --file ./salary-bands-2026.pdf \
  --metadata topic=hr access_level=internal \
  --auth-mode login

# Soft-delete a document (indexer removes its chunks on the next run)
az storage blob metadata update \
  --account-name "$STORAGE" --container-name documents \
  --name "hr/general/old-policy.pdf" \
  --metadata topic=hr access_level=general IsDeleted=true \
  --auth-mode login
```

To change a document's topic or access level, re-upload it to the new path with updated metadata and
soft-delete the old blob. Trigger the indexer immediately from `/admin` (**Reindex now**) or via the
Azure portal → AI Search → Indexers → **Run**.

---

## Company Branding

Set `company_name` in `terraform/terraform.tfvars`:

```hcl
company_name = "Acme Corp"
```

Run `terraform apply`. The name propagates to the App Service settings immediately — no redeploy needed. It appears in the header, the browser tab title, and the empty-state prompt.

---

## Going to Production

Use the `terraform/` config. Create `terraform/terraform.tfvars`:

```hcl
subscription_id         = "<your-subscription-id>"
company_name            = "Acme Corp"
enable_vnet_integration = true
```

Run `terraform apply`. With `enable_vnet_integration = true`:

- Private endpoints are created for OpenAI, AI Search, and Storage
- Public network access is disabled on all backend services
- App Service is integrated into the VNet via subnet delegation

> **Cost tip:** Buy a 1-year reserved instance for P1v3 on day one — saves ~35% (~$130 → ~$85/month).

### Terraform Remote State

The configs ship without a backend block so they work out of the box with local state. For any shared or production deployment, use an Azure Storage backend with state locking instead — local state has no locking and is easily lost.

1. Create the backend storage once (separate from the app's resource group so `destroy` never removes your state):

```bash
az group create --name tfstate-rg --location swedencentral
az storage account create --name <globally-unique-name> --resource-group tfstate-rg \
  --sku Standard_LRS --encryption-services blob --min-tls-version TLS1_2 \
  --allow-blob-public-access false
az storage container create --name tfstate --account-name <globally-unique-name> --auth-mode login
```

2. Add a backend block to `terraform/` (e.g. in `main.tf`), using one key per environment:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "<globally-unique-name>"
    container_name       = "tfstate"
    key                  = "rag/prod.terraform.tfstate"   # e.g. rag/dev, rag/prod
    use_azuread_auth     = true
  }
}
```

3. Run `terraform init -migrate-state`.

**RBAC for runners:** the identity running Terraform needs `Storage Blob Data Contributor` on the state storage account (state read/write + blob-lease locking). With `use_azuread_auth = true` no storage account keys are involved. Locking is automatic via blob leases — concurrent applies block instead of corrupting state.

---

## Cost Estimate

Retail USD, Sweden Central. Actual costs depend on usage volume and any EA/reserved-instance discounts.

### Test (~$15–30/month)

| Resource | SKU | Monthly |
|---|---|---|
| App Service Plan | B1 | $13 |
| Azure OpenAI | S0 GlobalStandard | pay-per-token ¹ |
| AI Search | Free | $0 |
| Blob Storage | Standard LRS | ~$0.10 |
| Log Analytics + App Insights | PerGB2018 | ~$0 ² |
| Private DNS zones ×3 | — | $1.50 |

¹ GPT-4o: $2.50/1M input tokens, $10/1M output tokens. text-embedding-3-small: $0.02/1M tokens.  
² Includes 5 GB/day free — a test workload stays within the free tier.

### Production (~$416/month fixed + OpenAI usage)

| Resource | SKU | Monthly |
|---|---|---|
| App Service Plan | P1v3 | $130 |
| Azure OpenAI | S0 GlobalStandard | pay-per-token ¹ |
| AI Search | Standard S1 | $245 |
| Blob Storage | Standard LRS | ~$5 |
| Log Analytics + App Insights | PerGB2018 | ~$13 |
| Managed identity (Easy Auth FIC) | — | $0 |
| Private DNS zones ×3 | — | $1.50 |
| Private endpoints ×3 | — | ~$22 |

---

## Variables Reference

Variables common to both configs:

| Variable | Default | Description |
|---|---|---|
| `subscription_id` | *(required)* | Azure Subscription ID |
| `company_name` | `"Contoso"` | Company name shown in the Aria UI header and empty-state prompt |
| `prefix` | `"rag"` | Short prefix for all resource names |
| `location` | `"swedencentral"` | Azure region |
| `openai_model` | `"gpt-4o"` | Chat model deployment name |
| `openai_model_version` | `"2024-11-20"` | Chat model version — check the [Azure OpenAI model lifecycle page](https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/model-retirements) for retirement dates and update this when a new version is available |
| `openai_capacity` | `10` | Capacity in K tokens per minute |
| `embedding_model` | `"text-embedding-3-small"` | Embedding model deployment name. Index vector dimensions are derived automatically (validated against a supported set) |
| `topics` | `{ hr = "HR", it = "IT" }` | Map of topic slug → display name. Each topic gets its own document folders, generated app roles, landing card, and chat at `/t/<slug>`. Adding one is a single entry plus `terraform apply` |
| `tiers` | `["general", "internal"]` | Ordered access tiers per topic, most-open first. Each higher tier generates a `<Tier>.Read` role granting that tier and every tier below. Use `["general"]` for topic-membership-only, or add `"confidential"` for a third level |
| `public_tier_mode` | `"all_users"` | `all_users`: any authenticated employee sees a topic's base (`general`) tier. `role_required`: even the base tier needs a `<topic>.General.Read` role and topics are hidden without a role |
| `create_role_groups` | `true` | Create one Entra security group per role and assign it, so admins manage access by group membership. Requires Entra ID P1+ |

`terraform/` only:

| Variable | Default | Description |
|---|---|---|
| `app_service_sku` | `"P1v3"` | App Service SKU. VNet integration requires Basic tier or higher (P1v3 recommended) |
| `enable_vnet_integration` | `false` | Enable VNet + private endpoints |
| `search_replica_count` | `1` | AI Search replicas. 2+ for a query SLA / HA. Each replica increases Search cost |
| `search_partition_count` | `1` | AI Search partitions. Increase for larger indexes / throughput. Partitions multiply Search cost |
| `alert_email` | `""` | Email for metric-alert notifications. Empty = alerts created without a notification target |

---

> **Security disclaimer — `terraform-free/`**
>
> The free config is intentionally cheap and accessible so you can try the app quickly. It comes with security trade-offs you must understand before putting real or sensitive data in:
>
> - **Storage account key in Terraform state.** The free AI Search tier has no Managed Identity, so the indexer authenticates to Blob Storage using a connection string (account key). That key is written into your Terraform state file. Anyone with read access to the state has full read/write access to the storage account. The `terraform/` config uses Managed Identity — no key is ever stored.
>
> - **API keys active on AI Search.** The free tier cannot disable local authentication, so AI Search API keys exist and are stored in Terraform state. These keys bypass the document access-level filter — anyone holding a key can query all documents regardless of their assigned role. The `terraform/` config sets `local_authentication_enabled = false` so no usable keys exist.
>
> - **No private endpoints.** All backend services are reachable over public internet endpoints. Access is gated by RBAC, but credentials obtained from a compromised workload would be exploitable from anywhere.
>
> **Summary:** `terraform-free/` is safe for demos, prototypes, and non-sensitive documents. Before loading content that actually matters, use the `terraform/` config and ensure your Terraform state backend has proper access controls.

---

## File Structure

```
azure-rag-foundry/
├── modules/                    # Shared Terraform modules (thin roots compose these)
│   ├── ai/                     # Azure OpenAI + model deployments, AI Search
│   ├── app/                    # App Service Plan + Web App, Log Analytics, App Insights
│   ├── identity/               # Entra app registration, generated per-topic app roles
│   ├── storage/               # Storage account, documents container, sample-doc upload
│   └── search_dataplane/       # AI Search index, datasource, skillset, indexer (chunked)
├── terraform/                  # Production root (standard tier, MSI, VNet-ready)
│   ├── main.tf                 # providers, resource group, IP detection
│   ├── locals.tf               # naming, network access logic
│   ├── variables.tf            # variables (topics, public_tier_mode, app_service_sku, …)
│   ├── network.tf              # VNet, subnets, private DNS zones, private endpoints
│   ├── ai_services.tf          # module "ai" + Search RBAC
│   ├── storage.tf              # module "storage"
│   ├── compute.tf              # module "app" + app settings
│   ├── security.tf             # module "identity" + Easy Auth FIC identity + App Service RBAC
│   ├── monitoring.tf           # Diagnostic settings -> Log Analytics + metric alerts
│   ├── search_dataplane.tf     # module "search_dataplane"
│   └── outputs.tf
├── terraform-free/             # Free-tier root (API keys, no VNet, zero-cost testing)
├── app/
│   ├── app.py                  # FastAPI: landing /, chat /t/<topic>, /admin, /api/* 
│   ├── access.py               # access-control contract (roles → topic×tier filter)
│   ├── requirements.txt
│   └── static/
│       ├── landing.html        # topic cards
│       ├── chat.html           # topic-scoped chat UI
│       └── admin.html          # document manager
├── tests/
│   └── test_access.py          # regression tests for the access filter (topic × tier)
└── sample-docs/                # uploaded automatically by terraform apply
    ├── hr/{general,internal,confidential}/
    └── it/{general,internal,confidential}/
```

---

## Before Going Live in Production

The infrastructure changes in [Going to Production](#going-to-production) handle the networking side. These are the additional concerns worth reviewing before real users and real documents go in.

### Security

- **Conditional Access** — enforce MFA and compliant-device policies on the Entra ID app registration. Aria inherits whatever Conditional Access policies your tenant applies to enterprise apps, but verify they're actually in effect.
- **OpenAI content filtering** — Azure OpenAI has built-in content filters (prompt shields, jailbreak detection). Review the default filter configuration in the Azure portal and tighten it if users could submit adversarial inputs.
- **Azure AI Content Safety (recommended next layer)** — the system prompt alone is not an enterprise safety boundary. For adversarial environments, add [Azure AI Content Safety](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/overview) in front of the model: screen the user prompt before search (prompt-injection / jailbreak detection), optionally screen retrieved context, and moderate the generated answer before returning it — logging each decision to Application Insights. Terraform can provision the resource and wire app settings, but enforcement is implemented in the app (`app.py`). This is a clean standalone increment and is intentionally not enabled by default.
- **App Role assignment review** — `Internal.Read` and `Confidential.Read` are powerful. Use Entra ID *groups* rather than individual users so access is managed through your existing group lifecycle (joiners/movers/leavers). Review assignments quarterly.
- **Secretless Easy Auth** — built-in auth has no client secret to rotate or leak. App Service authenticates to Entra ID with a federated identity credential backed by a dedicated user-assigned managed identity (`use_managed_identity_auth = true` on the identity module). The MI's client id is the only value in app settings; there is no secret in app settings, Key Vault, or Terraform state. Workforce tenants only.
- **Microsoft Defender for Cloud** — enable Defender plans for App Service and Storage. They surface misconfigurations and threat signals with minimal setup.

#### Extending the access model

The shipped model is two-dimensional: **topics** (the domain axis — HR, IT, finance, legal) × configurable **sensitivity tiers** (default `general` / `internal`), mapped to Entra app roles and enforced as an AI Search filter in `build_search_filter` (`app/access.py`). For finer control some deployments also want per-document group-level ACLs. To add that axis without re-architecting:

- Add `domain_id` and `acl_groups` (Entra group object IDs) fields to the index schema in `search_dataplane.tf`, populated per chunk the same way `access_level` is.
- Surface the user's Entra group claims to the app (groups claim in the token, with [group overage](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference#groups-overage-claim) handled via Microsoft Graph for users in many groups).
- Build the Search filter from both axes, e.g. `access_level in (...) and (domain_id in (...) or acl_groups/any(g: search.in(g, '<user groups>')))`.

Two patterns: a **shared index with ACL fields** (cheaper, simpler — what this repo uses) or an **index per tenant/domain** (stronger isolation, higher cost/ops). For the shared-index approach, add **regression tests** that prove a lower role cannot retrieve a higher-sensitivity document — that filter is the entire security boundary, so it must be tested, not assumed.

### Data & Compliance

- **Document approval process** — define who is authorized to upload documents to each access tier before ingestion. A document landing in `general/` by mistake is a data leak.
- **Personal data in documents** — if documents contain personal data (HR files, customer data), assess GDPR obligations: data subject access requests, retention limits, right to erasure. The search index holds chunked copies of all ingested content — deletion from blob alone is not enough (see [Managing the Knowledge Base](#managing-the-knowledge-base)).
- **Data residency** — all resources default to `swedencentral`. Verify this meets your organization's data residency requirements before ingesting sensitive content.
- **Log Analytics retention** — the workspace is set to 30 days. Adjust to match your compliance policy (`retention_in_days` in `compute.tf`).

### Reliability & Capacity

- **AI Search replicas** — the Standard SKU supports multiple replicas. A single replica has **no query SLA**. Set `search_replica_count = 2` for a query SLA (3 for read-write). Billing is replicas × partitions, so 2 replicas roughly doubles the Search base cost — this is left at `1` by default and is a deliberate cost decision.
- **App Service scale-out** — configure auto-scale rules on the App Service Plan (CPU/memory thresholds) so the app handles concurrent users without degrading.
- **OpenAI capacity (TPM)** — the default is 10K tokens per minute. At GPT-4o rates, that's roughly 5–10 concurrent users before throttling. Increase `openai_capacity` in `terraform.tfvars` based on expected load.
- **Search index backup** — the index can be fully rebuilt by deleting and recreating the AI Search data plane resources via `terraform apply`. Blob storage is the source of truth — the indexers rebuild the entire index from it.

### Monitoring & Cost

- **Built-in diagnostics & alerts** — `monitoring.tf` already sends App Service, OpenAI, AI Search, and Storage logs/metrics to Log Analytics, and provisions metric alerts for App Service 5xx + latency, AI Search throttling, and OpenAI errors. Set `alert_email` in `terraform.tfvars` to receive notifications.
- **Indexer-failure alerting** — indexer run failures are a data-plane signal, not a platform metric. Now that Search diagnostics flow to Log Analytics, add a scheduled **log-query alert** on the Search `OperationLogs` for indexer errors (embedding quota exceeded, storage access errors) to catch stale results before users do.
- **OpenAI budget alert** — token costs are unpredictable with user-driven input. Set a monthly budget alert in Azure Cost Management scoped to the resource group.
- **Usage dashboard** — build a workbook over the Log Analytics data tracking daily active users, average response latency, and OpenAI token consumption to spot anomalies early.

### Ongoing Operations

- **Indexer monitoring** — the indexers run every hour automatically. Set up an alert on AI Search indexer errors in Azure Monitor to catch failures (e.g. embedding quota exceeded, storage access errors) before users notice stale results.
- **Model version monitoring** — subscribe to Azure OpenAI service announcements or check the [model lifecycle page](https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/model-retirements) periodically. Updating the version is a one-line `terraform.tfvars` change — but it's easy to miss the retirement date if nobody is watching.
- **Offboarding** — define a process for removing role assignments when employees leave. Entra ID group-based access makes this automatic if your HR system drives group membership.

---

## Production Recommendations

### Application Gateway + WAF

For production deployments, consider placing an **Azure Application Gateway with WAF v2**
in front of the App Service for TLS termination, OWASP ruleset protection, and to remove
direct public exposure of the App Service.

Most enterprises already have an Application Gateway in their hub network — in that case
no new gateway resource is needed, only a listener and backend pool pointing at this App
Service need to be configured there.

### Confluence Integration

If your team uses Confluence, consider building an automation that pulls page content
via the **Confluence REST API v2** and uploads it as `.md` or `.txt` files into the
appropriate Blob Storage folder — the indexer handles the rest automatically.
Possible approaches include a scheduled Azure Function syncing changed pages nightly,
or a Confluence webhook triggering an upload on page create/update events.
Store the Confluence API token in Azure Key Vault, not in code.

---

## Destroying

```bash
terraform -chdir=terraform-free destroy
# or: terraform -chdir=terraform destroy
```

---

## Quick Deploy — All Commands

**Prerequisites:** Terraform ≥ 1.9, Azure CLI, `zip`

### Free tier (zero-cost testing)

```bash
# 1. Login
az login
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# 2. Check free AI Search quota (only one allowed per subscription)
az search service list --query "[?sku.name=='free'].{name:name, rg:resourceGroup}" -o table

# 3. Configure
cat > terraform-free/terraform.tfvars <<EOF
subscription_id = "YOUR_SUBSCRIPTION_ID"
company_name    = "Acme Corp"
EOF

# 4. Deploy everything (~10 min)
cd terraform-free && terraform init && terraform apply

# 5. Grant admin consent (Entra admin required)
az ad app permission admin-consent --id $(terraform output -raw entra_app_client_id)

# 6. Open the app
open $(terraform output -raw app_url)
```

### Production (standard tier, MSI, VNet-ready)

```bash
# 1. Login
az login
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# 2. Configure
cat > terraform/terraform.tfvars <<EOF
subscription_id = "YOUR_SUBSCRIPTION_ID"
company_name    = "Acme Corp"
EOF

# 3. Deploy everything (~10 min)
cd terraform && terraform init && terraform apply

# 4. Grant admin consent (Entra admin required)
az ad app permission admin-consent --id $(terraform output -raw entra_app_client_id)

# 5. Open the app
open $(terraform output -raw app_url)
```

**After opening the app:** assign users to app roles in the portal so they can log in.  
**Entra ID → Enterprise applications → `rag-auth-<suffix>` → Users and groups → Add assignment**

> Sample documents (one per access tier) are uploaded automatically by `terraform apply`. You can start chatting immediately — no manual uploads needed to test the app.
