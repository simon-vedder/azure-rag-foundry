# AI Search data plane (index, datasource, skillset, indexer) — see modules/search_dataplane.
#
# Free tier is fully key-based: the admin key authenticates the PUT calls, the OpenAI key powers
# the embedding skill, and the storage connection string lets the indexer read blobs. No managed
# identity, no shared private links — this is the trial/demo posture.
module "search_dataplane" {
  source = "../modules/search_dataplane"

  search_name    = module.ai.search_name
  container_name = module.storage.container_name
  admin_api_key  = module.ai.search_primary_key

  datasource_connection_string = module.storage.primary_connection_string

  openai_endpoint      = module.ai.openai_endpoint
  openai_api_key       = module.ai.openai_primary_key
  embedding_deployment = module.ai.embedding_deployment_name
  embedding_model      = var.embedding_model
  embedding_dimensions = module.ai.embedding_dimensions

  semantic_enabled = false
}
