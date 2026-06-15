# AI Search data plane (index, datasource, skillset, indexer) — see modules/search_dataplane.
#
# This config provisions the data plane from the machine running `terraform apply` via Entra ID
# (az rest). In a fully private posture (Search public access disabled) it must run from a runner
# with private network access to the Search service. The deployer needs Search Service Contributor
# + Search Index Data Contributor on the Search service.
module "search_dataplane" {
  source = "../modules/search_dataplane"

  search_name    = module.ai.search_name
  container_name = module.storage.container_name

  # Managed identity auth: the datasource references the storage account by resource ID and
  # the embedding skill carries no key — both resolve via the search service's identity.
  datasource_connection_string = "ResourceId=${module.storage.id};"

  openai_endpoint      = module.ai.openai_endpoint
  embedding_deployment = module.ai.embedding_deployment_name
  embedding_model      = var.embedding_model
  embedding_dimensions = module.ai.embedding_dimensions

  semantic_enabled = true

  depends_on = [
    azurerm_role_assignment.search_storage,
    azurerm_role_assignment.search_openai,
    time_sleep.search_rbac_propagation,
  ]
}
