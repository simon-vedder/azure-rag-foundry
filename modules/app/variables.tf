variable "app_name" {
  type = string
}

variable "plan_name" {
  type = string
}

variable "log_analytics_name" {
  type = string
}

variable "app_insights_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "sku_name" {
  type = string
}

variable "source_dir" {
  description = "Directory containing the FastAPI app; zipped and deployed via zip_deploy_file."
  type        = string
}

variable "zip_output_path" {
  type = string
}

variable "app_settings" {
  description = "App settings composed by the root config. The module adds App Insights, build and port settings."
  type        = map(string)
}

variable "vnet_subnet_id" {
  description = "Subnet for outbound VNet integration. Null disables VNet integration."
  type        = string
  default     = null
}

variable "auth_client_id" {
  type = string
}

variable "auth_tenant_id" {
  type = string
}

variable "user_assigned_identity_id" {
  description = "Optional user-assigned managed identity to attach to the web app alongside the system-assigned one. Used as the Easy Auth federated-credential subject for secretless auth."
  type        = string
  default     = null
}

variable "auth_client_secret_setting_name" {
  description = "App setting Easy Auth reads the client credential from. Default for a client secret; OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID for managed-identity (secretless) auth."
  type        = string
  default     = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
}

variable "sticky_app_setting_names" {
  description = "App setting names to mark slot-sticky (e.g. the Easy Auth MI override setting)."
  type        = list(string)
  default     = []
}
