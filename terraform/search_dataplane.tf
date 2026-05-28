# search_dataplane.tf
#
# Configures AI Search data plane objects via az CLI REST calls (api-version 2024-07-01).
# AI Search indexes, datasources, skillsets, and indexers are data-plane-only resources —
# they are not ARM resources and cannot be managed via azapi_resource or the azurerm provider.
# We call the Search service REST API directly, authenticated with an AAD token.
#
# Admin workflow (no scripts needed):
#   Upload .docx / .md / .txt / .pdf to the relevant Blob folder:
#     public/        -> access_level = "public"
#     internal/      -> access_level = "internal"
#     confidential/  -> access_level = "confidential"
#   Indexers run automatically every hour.

locals {
  search_endpoint    = "https://${azurerm_search_service.main.name}.search.windows.net"
  search_api_version = "2024-07-01"

  datasource_connection_string = "ResourceId=${azurerm_storage_account.main.id};"

  search_auth_setup = "TOKEN=$(az account get-access-token --resource 'https://search.azure.com' --query accessToken -o tsv) && AUTH_HEADER=\"Authorization: Bearer $TOKEN\""
}

# ---------------------------------------------------------------------------
# Index
# ---------------------------------------------------------------------------

resource "terraform_data" "search_index" {
  triggers_replace = [
    azurerm_search_service.main.id,
    azurerm_cognitive_deployment.embedding.id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      ${local.search_auth_setup}
      cat > /tmp/tf_rag_index.json << 'BODY'
      ${jsonencode({
        name = "rag-index"
        fields = [
          { name = "id", type = "Edm.String", key = true, filterable = true, retrievable = true, searchable = false },
          { name = "content", type = "Edm.String", searchable = true, retrievable = true, filterable = false },
          { name = "embedding", type = "Collection(Edm.Single)", searchable = true, retrievable = false, stored = false, dimensions = 1536, vectorSearchProfile = "vector-profile" },
          { name = "file_name", type = "Edm.String", searchable = false, filterable = true, retrievable = true },
          { name = "page_number", type = "Edm.Int32", filterable = true, retrievable = true },
          { name = "access_level", type = "Edm.String", filterable = true, retrievable = true, searchable = false },
          { name = "metadata_storage_path", type = "Edm.String", filterable = false, retrievable = true, searchable = false },
          { name = "metadata_storage_name", type = "Edm.String", filterable = false, retrievable = true, searchable = false },
        ]
        vectorSearch = {
          algorithms = [{ name = "hnsw-config", kind = "hnsw", hnswParameters = { m = 4, efConstruction = 400, efSearch = 500, metric = "cosine" } }]
          profiles   = [{ name = "vector-profile", algorithm = "hnsw-config" }]
        }
        semantic = {
          configurations = [{ name = "rag-semantic-config", prioritizedFields = { prioritizedContentFields = [{ fieldName = "content" }], prioritizedKeywordsFields = [{ fieldName = "file_name" }] } }]
        }
      })}
      BODY
      curl -sf -X PUT \
        "${local.search_endpoint}/indexes/rag-index?api-version=${local.search_api_version}" \
        -H 'Content-Type: application/json' \
        -H "$AUTH_HEADER" \
        --data-binary @/tmp/tf_rag_index.json
    EOT
  }

  depends_on = [azurerm_search_service.main]
}

# ---------------------------------------------------------------------------
# Datasources (one per access level folder)
# ---------------------------------------------------------------------------

resource "terraform_data" "datasource_public" {
  triggers_replace = [
    azurerm_search_service.main.id,
    azurerm_storage_container.documents.id,
    local.datasource_connection_string,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      ${local.search_auth_setup}
      cat > /tmp/tf_rag_ds_public.json << 'BODY'
      ${jsonencode({
        name  = "datasource-public"
        type  = "azureblob"
        credentials = { connectionString = local.datasource_connection_string }
        container   = { name = azurerm_storage_container.documents.name, query = "public" }
        dataChangeDetectionPolicy = {
          "@odata.type"           = "#Microsoft.Azure.Search.HighWaterMarkChangeDetectionPolicy"
          highWaterMarkColumnName = "metadata_storage_last_modified"
        }
        dataDeletionDetectionPolicy = {
          "@odata.type"         = "#Microsoft.Azure.Search.SoftDeleteColumnDeletionDetectionPolicy"
          softDeleteColumnName  = "IsDeleted"
          softDeleteMarkerValue = "true"
        }
      })}
      BODY
      curl -sf -X PUT \
        "${local.search_endpoint}/datasources/datasource-public?api-version=${local.search_api_version}" \
        -H 'Content-Type: application/json' \
        -H "$AUTH_HEADER" \
        --data-binary @/tmp/tf_rag_ds_public.json
    EOT
  }

  depends_on = [azurerm_search_service.main, azurerm_role_assignment.search_storage]
}

resource "terraform_data" "datasource_internal" {
  triggers_replace = [
    azurerm_search_service.main.id,
    azurerm_storage_container.documents.id,
    local.datasource_connection_string,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      ${local.search_auth_setup}
      cat > /tmp/tf_rag_ds_internal.json << 'BODY'
      ${jsonencode({
        name  = "datasource-internal"
        type  = "azureblob"
        credentials = { connectionString = local.datasource_connection_string }
        container   = { name = azurerm_storage_container.documents.name, query = "internal" }
        dataChangeDetectionPolicy = {
          "@odata.type"           = "#Microsoft.Azure.Search.HighWaterMarkChangeDetectionPolicy"
          highWaterMarkColumnName = "metadata_storage_last_modified"
        }
        dataDeletionDetectionPolicy = {
          "@odata.type"         = "#Microsoft.Azure.Search.SoftDeleteColumnDeletionDetectionPolicy"
          softDeleteColumnName  = "IsDeleted"
          softDeleteMarkerValue = "true"
        }
      })}
      BODY
      curl -sf -X PUT \
        "${local.search_endpoint}/datasources/datasource-internal?api-version=${local.search_api_version}" \
        -H 'Content-Type: application/json' \
        -H "$AUTH_HEADER" \
        --data-binary @/tmp/tf_rag_ds_internal.json
    EOT
  }

  depends_on = [azurerm_search_service.main, azurerm_role_assignment.search_storage]
}

resource "terraform_data" "datasource_confidential" {
  triggers_replace = [
    azurerm_search_service.main.id,
    azurerm_storage_container.documents.id,
    local.datasource_connection_string,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      ${local.search_auth_setup}
      cat > /tmp/tf_rag_ds_confidential.json << 'BODY'
      ${jsonencode({
        name  = "datasource-confidential"
        type  = "azureblob"
        credentials = { connectionString = local.datasource_connection_string }
        container   = { name = azurerm_storage_container.documents.name, query = "confidential" }
        dataChangeDetectionPolicy = {
          "@odata.type"           = "#Microsoft.Azure.Search.HighWaterMarkChangeDetectionPolicy"
          highWaterMarkColumnName = "metadata_storage_last_modified"
        }
        dataDeletionDetectionPolicy = {
          "@odata.type"         = "#Microsoft.Azure.Search.SoftDeleteColumnDeletionDetectionPolicy"
          softDeleteColumnName  = "IsDeleted"
          softDeleteMarkerValue = "true"
        }
      })}
      BODY
      curl -sf -X PUT \
        "${local.search_endpoint}/datasources/datasource-confidential?api-version=${local.search_api_version}" \
        -H 'Content-Type: application/json' \
        -H "$AUTH_HEADER" \
        --data-binary @/tmp/tf_rag_ds_confidential.json
    EOT
  }

  depends_on = [azurerm_search_service.main, azurerm_role_assignment.search_storage]
}

# ---------------------------------------------------------------------------
# Skillset
# ---------------------------------------------------------------------------

resource "terraform_data" "skillset" {
  triggers_replace = [
    azurerm_search_service.main.id,
    azurerm_cognitive_account.openai.id,
    azurerm_cognitive_account.openai.endpoint,
    azurerm_cognitive_deployment.embedding.id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      ${local.search_auth_setup}
      cat > /tmp/tf_rag_skillset.json << 'BODY'
      ${jsonencode({
        name        = "rag-skillset"
        description = "Generates embeddings for each document via Azure OpenAI"
        skills = [
          {
            "@odata.type" = "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill"
            name          = "embedding-skill"
            description   = "Embeds each document using Azure OpenAI text-embedding-3-small"
            context       = "/document"
            resourceUri   = azurerm_cognitive_account.openai.endpoint
            deploymentId  = azurerm_cognitive_deployment.embedding.name
            modelName     = var.embedding_model
            dimensions    = 1536
            inputs        = [{ name = "text", source = "/document/content" }]
            outputs       = [{ name = "embedding", targetName = "embedding" }]
          }
        ]
      })}
      BODY
      curl -sf -X PUT \
        "${local.search_endpoint}/skillsets/rag-skillset?api-version=${local.search_api_version}" \
        -H 'Content-Type: application/json' \
        -H "$AUTH_HEADER" \
        --data-binary @/tmp/tf_rag_skillset.json
    EOT
  }

  depends_on = [
    terraform_data.search_index,
    terraform_data.datasource_public,
    terraform_data.datasource_internal,
    terraform_data.datasource_confidential,
    azurerm_role_assignment.search_openai,
  ]
}

# ---------------------------------------------------------------------------
# Indexers (one per datasource, all sharing the same skillset and index)
# ---------------------------------------------------------------------------

locals {
  _common_field_mappings = [
    { sourceFieldName = "metadata_storage_path", targetFieldName = "id", mappingFunction = { name = "base64Encode" } },
    { sourceFieldName = "metadata_storage_name", targetFieldName = "file_name" },
    { sourceFieldName = "metadata_storage_path", targetFieldName = "metadata_storage_path" },
    { sourceFieldName = "metadata_storage_name", targetFieldName = "metadata_storage_name" },
    # metadata_storage_path = https://{account}.blob.core.windows.net/documents/{folder}/{file}
    # split("/", 4) extracts the folder name (public | internal | confidential)
    { sourceFieldName = "metadata_storage_path", targetFieldName = "access_level", mappingFunction = { name = "extractTokenAtPosition", parameters = { delimiter = "/", position = 4 } } },
  ]
  _common_output_mappings = [
    { sourceFieldName = "/document/embedding", targetFieldName = "embedding" },
  ]
  _common_indexer_params = {
    schedule   = { interval = "PT1H" }
    parameters = { configuration = { dataToExtract = "contentAndMetadata", parsingMode = "default" } }
    targetIndexName = "rag-index"
    skillsetName    = "rag-skillset"
    fieldMappings       = local._common_field_mappings
    outputFieldMappings = local._common_output_mappings
  }
}

resource "terraform_data" "indexer_public" {
  triggers_replace = [terraform_data.skillset.id, terraform_data.datasource_public.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      ${local.search_auth_setup}
      cat > /tmp/tf_rag_indexer_public.json << 'BODY'
      ${jsonencode(merge(local._common_indexer_params, { name = "indexer-public", dataSourceName = "datasource-public" }))}
      BODY
      curl -sf -X PUT \
        "${local.search_endpoint}/indexers/indexer-public?api-version=${local.search_api_version}" \
        -H 'Content-Type: application/json' \
        -H "$AUTH_HEADER" \
        --data-binary @/tmp/tf_rag_indexer_public.json
    EOT
  }

  depends_on = [terraform_data.search_index, terraform_data.skillset]
}

resource "terraform_data" "indexer_internal" {
  triggers_replace = [terraform_data.skillset.id, terraform_data.datasource_internal.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      ${local.search_auth_setup}
      cat > /tmp/tf_rag_indexer_internal.json << 'BODY'
      ${jsonencode(merge(local._common_indexer_params, { name = "indexer-internal", dataSourceName = "datasource-internal" }))}
      BODY
      curl -sf -X PUT \
        "${local.search_endpoint}/indexers/indexer-internal?api-version=${local.search_api_version}" \
        -H 'Content-Type: application/json' \
        -H "$AUTH_HEADER" \
        --data-binary @/tmp/tf_rag_indexer_internal.json
    EOT
  }

  depends_on = [terraform_data.search_index, terraform_data.skillset]
}

resource "terraform_data" "indexer_confidential" {
  triggers_replace = [terraform_data.skillset.id, terraform_data.datasource_confidential.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      ${local.search_auth_setup}
      cat > /tmp/tf_rag_indexer_confidential.json << 'BODY'
      ${jsonencode(merge(local._common_indexer_params, { name = "indexer-confidential", dataSourceName = "datasource-confidential" }))}
      BODY
      curl -sf -X PUT \
        "${local.search_endpoint}/indexers/indexer-confidential?api-version=${local.search_api_version}" \
        -H 'Content-Type: application/json' \
        -H "$AUTH_HEADER" \
        --data-binary @/tmp/tf_rag_indexer_confidential.json
    EOT
  }

  depends_on = [terraform_data.search_index, terraform_data.skillset]
}
