# Azure RAG Foundry — Aria

**Aria** is a ready-to-deploy enterprise RAG chatbot built on Azure. Employees authenticate with their company's Entra ID account and ask questions against internal documents in natural language. Answers stream back in real time, grounded in the documents — not hallucinated.

Access is role-based: users only see documents they're authorized for. All service-to-service communication uses Managed Identity — no API keys anywhere.

The stack is production-ready from day one. Two variables flip it from a €15/month test setup to a fully private, VNet-isolated production deployment.

---

## Contents

- [What you get](#what-you-get)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quickstart](#quickstart)
  - [1. Login](#1-login)
  - [2. Check free AI Search quota](#2-check-free-ai-search-quota)
  - [3. Configure Terraform](#3-configure-terraform)
  - [4. Add your company logo](#4-add-your-company-logo-optional)
  - [5. Deploy infrastructure](#5-deploy-infrastructure)
  - [6. Deploy the app](#6-deploy-the-app)
  - [7. Grant admin consent](#7-grant-admin-consent-entra-admin-required)
  - [8. Assign app roles to users](#8-assign-app-roles-to-users)
  - [9. Grant your own RBAC roles for ingestion](#9-grant-your-own-rbac-roles-for-ingestion)
  - [10. Upload documents and ingest](#10-upload-documents-and-ingest)
  - [11. Open the app](#11-open-the-app)
- [Managing the Knowledge Base](#managing-the-knowledge-base)
  - [Adding or updating documents](#adding-or-updating-documents)
  - [Deleting documents](#deleting-documents)
  - [Changing a document's access level](#changing-a-documents-access-level)
  - [Automating ingestion](#automating-ingestion)
- [Company Branding](#company-branding)
  - [Company name](#company-name)
  - [Logo](#logo)
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
- [Destroying](#destroying)

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
- **Company branding** — swap in your company name and logo with one Terraform variable and one file

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
- Python 3.12 (for running `ingest.py` locally)
- `zip` (bundled on macOS/Linux; on Windows use WSL or Git Bash)

---

## Quickstart

### 1. Login

```bash
az login
az account set --subscription "<your-subscription-id>"
```

### 2. Check free AI Search quota

Only one free-tier AI Search service is allowed per subscription:

```bash
az search service list --query "[?sku.name=='free'].{name:name, rg:resourceGroup}" -o table
```

If one already exists, set `search_sku = "basic"` in your `terraform.tfvars` (step 3).

### 3. Configure Terraform

Create `terraform/terraform.tfvars`:

```hcl
subscription_id = "<your-subscription-id>"
company_name    = "Acme Corp"           # shown in the Aria UI
```

All other variables have sensible defaults. See [variables reference](#variables-reference) for the full list.

### 4. Add your company logo (optional)

Drop a logo file into the `branding/` folder at the repo root:

```
branding/
  logo.png    # also accepts .svg or .jpg
```

Terraform uploads this to a public blob container and wires the URL into the app automatically. If no logo is provided, Aria's default gem icon is used.

### 5. Deploy infrastructure

```bash
cd terraform
terraform init
terraform apply
```

This takes 5–10 minutes. Resources created: resource group, OpenAI account, AI Search, Storage, App Service, VNet, private DNS zones, App Registration, RBAC assignments.

### 6. Deploy the app

From the repo root:

```bash
./deploy.sh
```

This zips the `app/` folder, reads Terraform outputs for the target App Service, and deploys. Build + startup on Azure takes ~5 minutes.

### 7. Grant admin consent (Entra admin required)

The App Registration requests `User.Read` from Microsoft Graph. An Entra admin must grant tenant-wide consent:

```bash
CLIENT_ID=$(terraform -chdir=terraform output -raw entra_app_client_id)
az ad app permission admin-consent --id "$CLIENT_ID"
```

Or in the portal: **Entra ID → App registrations → `rag-rag-<suffix>` → API permissions → Grant admin consent**.

### 8. Assign app roles to users

Terraform creates the roles but deliberately does not assign them — you control who gets access.

In the portal: **Entra ID → Enterprise applications → `rag-rag-<suffix>` → Users and groups → Add user/group**

| Role | Documents accessible |
|---|---|
| *(any authenticated user)* | `public/` |
| `Internal Reader` | `public/` + `internal/` |
| `Confidential Reader` | `public/` + `internal/` + `confidential/` |

### 9. Grant your own RBAC roles for ingestion

`ingest.py` runs locally under your `az login` credentials. Assign yourself the required roles once:

```bash
RG=$(terraform -chdir=terraform output -raw resource_group_name)
ME=$(az ad signed-in-user show --query id -o tsv)

OAI_ID=$(az cognitiveservices account list -g "$RG" --query "[0].id" -o tsv)
SRCH_ID=$(az search service list -g "$RG" --query "[0].id" -o tsv)
ST_ID=$(az storage account list -g "$RG" --query "[0].id" -o tsv)

az role assignment create --role "Cognitive Services OpenAI User"  --assignee "$ME" --scope "$OAI_ID"
az role assignment create --role "Search Index Data Contributor"   --assignee "$ME" --scope "$SRCH_ID"
az role assignment create --role "Search Service Contributor"      --assignee "$ME" --scope "$SRCH_ID"
az role assignment create --role "Storage Blob Data Reader"        --assignee "$ME" --scope "$ST_ID"
```

> Role assignments can take 5–10 minutes to propagate in Azure AD.

### 10. Upload documents and ingest

Documents are organized by access level using folder prefixes inside the `documents` blob container:

```
documents/
  public/         → all authenticated users
  internal/       → Internal Reader role required
  confidential/   → Confidential Reader role required
```

Upload your files:

```bash
STORAGE=$(terraform -chdir=terraform output -raw storage_account_name)

az storage blob upload-batch \
  --account-name "$STORAGE" \
  --destination documents/public \
  --source ./my-docs/public/ \
  --auth-mode login
```

Run the ingestion pipeline:

```bash
cd app
pip install -r requirements.txt

export AZURE_OPENAI_ENDPOINT=$(terraform -chdir=../terraform output -raw openai_endpoint)
export AZURE_SEARCH_ENDPOINT=$(terraform -chdir=../terraform output -raw search_endpoint)
export AZURE_STORAGE_ACCOUNT=$(terraform -chdir=../terraform output -raw storage_account_name)

python ingest.py
```

Supported formats: **PDF, DOCX, TXT**. Text is chunked at 700 tokens with 70-token overlap and embedded with `text-embedding-3-small`.

Re-run `ingest.py` any time you add or update documents.

### 11. Open the app

```bash
terraform -chdir=terraform output -raw app_url
```

---

## Managing the Knowledge Base

Once the initial setup is done, keeping the knowledge base up to date is a two-step cycle: **upload to blob storage → run `ingest.py`**.

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

Then re-run the ingestion pipeline:

```bash
cd app
python ingest.py
```

Re-running is safe. Each chunk gets a deterministic ID based on filename, page number, and chunk position — so existing chunks are overwritten in place (upsert), not duplicated.

### Deleting documents

Deleting a blob from storage does **not** automatically remove its chunks from the search index. You need to clean them up manually.

Delete the blob first:

```bash
az storage blob delete \
  --account-name "$STORAGE" \
  --container-name documents \
  --name "public/old-policy.pdf" \
  --auth-mode login
```

Then delete its chunks from the index. The simplest way is to rebuild the index from scratch:

```bash
cd app
python ingest.py --rebuild
```

> **Note:** `--rebuild` is not implemented in the current `ingest.py`. Until then, delete orphaned chunks via the Azure portal (AI Search → your index → Search explorer → filter by `file_name`) or use the REST API. A `--rebuild` flag (drop + recreate index, then re-ingest all blobs) is a straightforward addition if needed.

### Changing a document's access level

Move it to a different folder prefix. The access level is derived from the folder name at ingest time.

```bash
# Move from public/ to internal/
az storage blob copy start \
  --account-name "$STORAGE" \
  --destination-container documents \
  --destination-blob "internal/policy.pdf" \
  --source-blob "public/policy.pdf" \
  --source-container documents \
  --auth-mode login

az storage blob delete \
  --account-name "$STORAGE" \
  --container-name documents \
  --name "public/policy.pdf" \
  --auth-mode login
```

Then re-run `ingest.py`. The existing chunks under the old path remain until you delete them (see above); the new path gets indexed with the updated access level.

### Automating ingestion

For production, trigger `ingest.py` automatically instead of running it manually:

- **Azure DevOps / GitHub Actions** — run `ingest.py` as a pipeline step after uploading documents
- **Azure Function** — trigger on `BlobCreated` events from the storage account
- **Scheduled job** — run nightly via a cron-based pipeline if documents are updated in batch

The pipeline just needs the four environment variables (`AZURE_OPENAI_ENDPOINT`, `AZURE_SEARCH_ENDPOINT`, `AZURE_STORAGE_ACCOUNT`, and appropriate RBAC roles on a service principal or managed identity).

---

## Company Branding

Aria is designed to be white-labeled. Two inputs control all branding — both are set once and require no code changes.

### Company name

Set `company_name` in `terraform/terraform.tfvars`:

```hcl
company_name = "Acme Corp"
```

Run `terraform apply`. The name propagates to the App Service settings immediately — no redeploy needed. It appears in the header, the browser tab title, and the empty-state prompt.

### Logo

Place a logo file in the `branding/` folder at the repo root:

```
branding/
  logo.png    # PNG recommended; .svg and .jpg also supported
```

Run `terraform apply`. Terraform uploads the file to a dedicated public container in your storage account and sets the URL in the App Service settings automatically. The logo replaces the default gem icon in the header. If the file is removed and `terraform apply` is run again, the gem icon returns.

Logo requirements: any size (displayed at 34×34 px in the header); transparent background recommended for PNG/SVG.

---

## Going to Production

All upgrade points are marked `# PROD UPGRADE` in `terraform/variables.tf`. Add the relevant variables to your `terraform.tfvars`:

```hcl
subscription_id         = "<your-subscription-id>"
company_name            = "Acme Corp"
app_service_sku         = "P1v3"
search_sku              = "standard"
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

| Variable | Default | Description |
|---|---|---|
| `subscription_id` | *(required)* | Azure Subscription ID |
| `company_name` | `"Contoso"` | Company name shown in the Aria UI |
| `prefix` | `"rag"` | Short prefix for all resource names |
| `location` | `"swedencentral"` | Azure region |
| `app_service_sku` | `"B1"` | App Service SKU. Prod: `"P1v3"` |
| `openai_model` | `"gpt-4o"` | Chat model deployment name |
| `openai_model_version` | `"2024-11-20"` | Chat model version — check the [Azure OpenAI model lifecycle page](https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/model-retirements) for retirement dates and update this when a new version is available |
| `openai_capacity` | `10` | Capacity in K tokens per minute |
| `search_sku` | `"free"` | AI Search SKU. Prod: `"standard"` |
| `enable_vnet_integration` | `false` | Enable VNet + private endpoints. Requires P1v3+ |

---

## File Structure

```
azure-rag-foundry/
├── terraform/
│   ├── main.tf           # providers, resource group
│   ├── locals.tf         # naming, logo detection
│   ├── variables.tf      # all variables — SKU upgrade points marked
│   ├── network.tf        # VNet, subnets, private DNS zones, private endpoints
│   ├── ai_services.tf    # Azure OpenAI + model deployments, AI Search
│   ├── storage.tf        # Storage account, documents container, branding container
│   ├── compute.tf        # App Service Plan + Web App (Easy Auth, Managed Identity)
│   ├── security.tf       # App Registration, App Roles, RBAC assignments
│   └── outputs.tf
├── app/
│   ├── app.py            # FastAPI: /chat (SSE), /branding, /, /health
│   ├── ingest.py         # blob → extract → chunk → embed → AI Search index
│   ├── requirements.txt
│   └── static/
│       └── index.html    # Aria chat UI
├── branding/
│   └── logo.png          # ← drop your company logo here (.svg and .jpg also work)
└── deploy.sh             # zips app/, reads Terraform outputs, deploys to App Service
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
- **Search index backup** — the index can be fully rebuilt from blob storage by re-running `ingest.py`. Document this as your recovery procedure and keep blob storage as the source of truth.

### Monitoring & Cost

- **Application Insights alerts** — set up alert rules on `requests/failed` rate and `dependencies/failed` (OpenAI and Search calls). A spike in failures usually means a quota limit or a model retirement.
- **OpenAI budget alert** — token costs are unpredictable with user-driven input. Set a monthly budget alert in Azure Cost Management scoped to the resource group.
- **Usage dashboard** — the Log Analytics workspace already collects App Service logs. Build a simple workbook tracking daily active users, average response latency, and OpenAI token consumption to spot anomalies early.

### Ongoing Operations

- **Automate ingestion** — a blob-triggered Azure Function is the production-grade replacement for running `ingest.py` manually. Trigger on `BlobCreated` and `BlobModified` events from the `documents` container.
- **Model version monitoring** — subscribe to Azure OpenAI service announcements or check the [model lifecycle page](https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/model-retirements) periodically. Updating the version is a one-line `terraform.tfvars` change — but it's easy to miss the retirement date if nobody is watching.
- **Offboarding** — define a process for removing role assignments when employees leave. Entra ID group-based access makes this automatic if your HR system drives group membership.

---

## Destroying

```bash
terraform -chdir=terraform destroy
```
