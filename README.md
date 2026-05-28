# Azure RAG Foundry — Aria

**Aria** is a ready-to-deploy enterprise RAG chatbot built on Azure. Employees authenticate with their company's Entra ID account and ask questions against internal documents in natural language. Answers stream back in real time, grounded in the documents — not hallucinated.

Access is role-based: users only see documents they're authorized for.

Two Terraform configs are included:

| Config | Tier | Cost | Use case |
|---|---|---|---|
| `terraform/` | Standard | ~$416/month | Production — MSI everywhere, no API keys, VNet-ready |
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
- **Hybrid search** — vector + keyword search across your documents (AI Search)
- **Role-based document access** — `public`, `internal`, `confidential` access levels enforced server-side
- **Entra ID auth** — Easy Auth blocks unauthenticated users before they reach your app
- **Zero API keys** — App Service Managed Identity accesses OpenAI, Search, and Storage via RBAC
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

Or in the portal: **Entra ID → App registrations → `rag-rag-<suffix>` → API permissions → Grant admin consent**.

### 6. Assign app roles to users

Terraform creates the roles but deliberately does not assign them — you control who gets access.

In the portal: **Entra ID → Enterprise applications → `rag-rag-<suffix>` → Users and groups → Add user/group**

| Role | Documents accessible |
|---|---|
| *(any authenticated user)* | `public/` |
| `Internal Reader` | `public/` + `internal/` |
| `Confidential Reader` | `public/` + `internal/` + `confidential/` |

### 7. Upload your own documents (optional)

Sample documents are already in place from the `terraform apply` in step 4 — you can start chatting as soon as steps 5 and 6 are done. View `storage.tf` to see where and how the sample documents are uploaded.

This step is only needed when you want to load your own content. Documents are organized by access level using folder prefixes inside the `documents` blob container:

```
documents/
  public/         → all authenticated users
  internal/       → Internal Reader role required
  confidential/   → Confidential Reader role required
```

```bash
STORAGE=$(terraform -chdir=terraform output -raw storage_account_name)

az storage blob upload-batch \
  --account-name "$STORAGE" \
  --destination documents/public \
  --source ./my-docs/public/ \
  --auth-mode login
```

Supported formats: **PDF, DOCX, TXT, MD, CSV**. The AI Search indexer picks up new files automatically every hour. To trigger it immediately: Azure portal → AI Search → Indexers → select indexer → **Run**.

> **Permissions:** uploading requires `Storage Blob Data Contributor` on the storage account. Assign it once: `az role assignment create --role "Storage Blob Data Contributor" --assignee "<your-object-id>" --scope "<storage-account-id>"`

### 8. Open the app

```bash
terraform -chdir=terraform-free output -raw app_url
# or: terraform -chdir=terraform output -raw app_url
```

---

## Managing the Knowledge Base

Ingestion is fully automated. The AI Search indexers run every hour and pick up new, modified, and deleted documents automatically. The only admin task is managing files in blob storage.

### Adding or updating documents

Upload the new or updated file to the correct access-level folder:

```bash
STORAGE=$(terraform -chdir=terraform output -raw storage_account_name)

# Public document (all authenticated users)
az storage blob upload \
  --account-name "$STORAGE" \
  --container-name documents \
  --name "public/q1-2026-report.pdf" \
  --file ./q1-2026-report.pdf \
  --auth-mode login

# Internal document (Internal Reader role required)
az storage blob upload \
  --account-name "$STORAGE" \
  --container-name documents \
  --name "internal/salary-bands-2026.pdf" \
  --file ./salary-bands-2026.pdf \
  --auth-mode login
```

The indexer picks up the new file on the next scheduled run (up to 1 hour). To trigger it immediately: Azure portal → AI Search → Indexers → select the relevant indexer → **Run**.

### Deleting documents

The indexers use a soft-delete detection policy. To delete a document from the index:

1. Set the `IsDeleted` metadata property on the blob to `"true"`:

```bash
az storage blob metadata update \
  --account-name "$STORAGE" \
  --container-name documents \
  --name "public/old-policy.pdf" \
  --metadata IsDeleted=true \
  --auth-mode login
```

2. Wait for the next indexer run (or trigger it manually). The indexer removes the document's chunks from the index.
3. Delete the blob itself once the indexer has processed it.

### Changing a document's access level

Move it to a different folder prefix — the access level is derived from the folder name automatically.

```bash
# Copy from public/ to internal/
az storage blob copy start \
  --account-name "$STORAGE" \
  --destination-container documents \
  --destination-blob "internal/policy.pdf" \
  --source-blob "public/policy.pdf" \
  --source-container documents \
  --auth-mode login

# Mark the old blob for deletion
az storage blob metadata update \
  --account-name "$STORAGE" \
  --container-name documents \
  --name "public/policy.pdf" \
  --metadata IsDeleted=true \
  --auth-mode login
```

On the next indexer run, the old chunks are removed and new chunks with the updated access level are created.

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
| `embedding_model` | `"text-embedding-3-small"` | Embedding model deployment name. Changing this requires updating index dimensions |

`terraform/` only:

| Variable | Default | Description |
|---|---|---|
| `app_service_sku` | `"P1v3"` | App Service SKU. P1v3 required for VNet integration |
| `enable_vnet_integration` | `false` | Enable VNet + private endpoints |

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
├── terraform/                  # Production config (standard tier, MSI, VNet-ready)
│   ├── main.tf                 # providers, resource group, IP detection
│   ├── locals.tf               # naming, network access logic
│   ├── variables.tf            # variables (app_service_sku, enable_vnet_integration)
│   ├── network.tf              # VNet, subnets, private DNS zones, private endpoints
│   ├── ai_services.tf          # Azure OpenAI + model deployments, AI Search (standard)
│   ├── storage.tf              # Storage account, documents container, sample docs
│   ├── compute.tf              # App Service Plan + Web App (Easy Auth, Managed Identity)
│   ├── security.tf             # App Registration, App Roles, RBAC assignments
│   ├── search_dataplane.tf     # AI Search data plane: index, datasources, skillset, indexers
│   └── outputs.tf
├── terraform-free/             # Free-tier config (API keys, no VNet, zero-cost testing)
│   ├── main.tf
│   ├── locals.tf
│   ├── variables.tf
│   ├── ai_services.tf          # AI Search free tier (API keys, no MSI)
│   ├── storage.tf
│   ├── compute.tf
│   ├── security.tf
│   ├── search_dataplane.tf     # uses OpenAI API key in skillset (no MSI)
│   └── outputs.tf
├── app/
│   ├── app.py                  # FastAPI: /chat (SSE), /branding, /, /health
│   ├── requirements.txt
│   └── static/
│       └── index.html          # Aria chat UI
└── sample-docs/
    ├── public/                 # uploaded automatically by terraform apply
    ├── internal/
    └── confidential/
```

---

## Before Going Live in Production

The infrastructure changes in [Going to Production](#going-to-production) handle the networking side. These are the additional concerns worth reviewing before real users and real documents go in.

### Security

- **Conditional Access** — enforce MFA and compliant-device policies on the Entra ID app registration. Aria inherits whatever Conditional Access policies your tenant applies to enterprise apps, but verify they're actually in effect.
- **OpenAI content filtering** — Azure OpenAI has built-in content filters (prompt shields, jailbreak detection). Review the default filter configuration in the Azure portal and tighten it if users could submit adversarial inputs.
- **App Role assignment review** — `Internal.Read` and `Confidential.Read` are powerful. Use Entra ID *groups* rather than individual users so access is managed through your existing group lifecycle (joiners/movers/leavers). Review assignments quarterly.
- **Application secret rotation** — the Easy Auth client secret is set to expire in 2099. Consider a shorter window (1–2 years) and automate rotation via Key Vault.
- **Microsoft Defender for Cloud** — enable Defender plans for App Service and Storage. They surface misconfigurations and threat signals with minimal setup.

### Data & Compliance

- **Document approval process** — define who is authorized to upload documents to each access tier before ingestion. A document landing in `public/` by mistake is a data leak.
- **Personal data in documents** — if documents contain personal data (HR files, customer data), assess GDPR obligations: data subject access requests, retention limits, right to erasure. The search index holds chunked copies of all ingested content — deletion from blob alone is not enough (see [Managing the Knowledge Base](#managing-the-knowledge-base)).
- **Data residency** — all resources default to `swedencentral`. Verify this meets your organization's data residency requirements before ingesting sensitive content.
- **Log Analytics retention** — the workspace is set to 30 days. Adjust to match your compliance policy (`retention_in_days` in `compute.tf`).

### Reliability & Capacity

- **AI Search replicas** — the Standard S1 SKU supports multiple replicas. Add at least one replica (`replica_count = 2`) for high availability — a single replica has no SLA.
- **App Service scale-out** — configure auto-scale rules on the App Service Plan (CPU/memory thresholds) so the app handles concurrent users without degrading.
- **OpenAI capacity (TPM)** — the default is 10K tokens per minute. At GPT-4o rates, that's roughly 5–10 concurrent users before throttling. Increase `openai_capacity` in `terraform.tfvars` based on expected load.
- **Search index backup** — the index can be fully rebuilt by deleting and recreating the AI Search data plane resources via `terraform apply`. Blob storage is the source of truth — the indexers rebuild the entire index from it.

### Monitoring & Cost

- **Application Insights alerts** — set up alert rules on `requests/failed` rate and `dependencies/failed` (OpenAI and Search calls). A spike in failures usually means a quota limit or a model retirement.
- **OpenAI budget alert** — token costs are unpredictable with user-driven input. Set a monthly budget alert in Azure Cost Management scoped to the resource group.
- **Usage dashboard** — the Log Analytics workspace already collects App Service logs. Build a simple workbook tracking daily active users, average response latency, and OpenAI token consumption to spot anomalies early.

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
**Entra ID → Enterprise applications → `rag-rag-<suffix>` → Users and groups → Add assignment**

> Sample documents (one per access tier) are uploaded automatically by `terraform apply`. You can start chatting immediately — no manual uploads needed to test the app.
