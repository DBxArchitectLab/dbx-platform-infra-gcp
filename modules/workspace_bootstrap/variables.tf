variable "databricks_account_id" {
  description = "Databricks account ID (required by generated root account provider)"
  type        = string
}

variable "gcp_project_id" {
  description = "GCP project for the Unity Catalog bucket (also used by the generated google provider)"
  type        = string
}

variable "databricks_host" {
  description = "Workspace URL for workspace-level Databricks provider"
  type        = string
}

variable "workspace_id" {
  description = "ID of this environment's workspace; the catalog, external location and storage credential are bound to it only"
  type        = number
}

variable "region" {
  description = "GCP region for the GCS bucket (e.g. us-central1); use the workspace region"
  type        = string
}

variable "metastore_id" {
  description = "Expected Unity Catalog metastore ID, checked by the validation notebook; null or empty skips that check"
  type        = string
  nullable    = true
  default     = null
}

variable "platform_admin_group_name" {
  description = "Account group expected to be workspace admin, checked by the validation notebook; null skips that check"
  type        = string
  nullable    = true
  default     = null
}

variable "bucket_name" {
  description = "Globally unique GCS bucket name for the Unity Catalog external location and catalog managed storage"
  type        = string
}

variable "bucket_force_destroy" {
  description = "Allow Terraform to delete the bucket even if it still contains objects"
  type        = bool
  default     = false
}

variable "catalog_name" {
  description = "Unity Catalog catalog name to create"
  type        = string
}

variable "catalog_managed_prefix" {
  description = "Path prefix inside the bucket for managed catalog data (separate from external location root)"
  type        = string
  default     = "managed"
}

variable "external_location_name" {
  description = "Unity Catalog external location name"
  type        = string
}

variable "storage_credential_name" {
  description = "Databricks storage credential name; if null, defaults to \"<external_location_name>_cred\""
  type        = string
  nullable    = true
  default     = null
}

variable "enable_external_location_grants" {
  description = "If true, apply databricks_grants on the external location for external_location_grant_principals."
  type        = bool
  default     = true
}

variable "external_location_grant_principals" {
  description = "Principals to grant external location privileges: group names, user emails, or service principal application IDs."
  type        = list(string)
}

variable "external_location_owner" {
  description = "Unity Catalog owner for the external location; null uses the first entry in external_location_grant_principals."
  type        = string
  nullable    = true
  default     = null
}

variable "external_location_grant_privileges" {
  description = "Unity Catalog privileges for the external location. MANAGE is required for Terraform to update the location in place (see external-location module comments)."
  type        = list(string)
  default = [
    "MANAGE",
    "READ_FILES",
    "WRITE_FILES",
    "CREATE_EXTERNAL_TABLE",
  ]
}

variable "enable_catalog_grants" {
  description = "If true, apply databricks_grants on the catalog for catalog_grant_principals."
  type        = bool
  default     = true
}

variable "catalog_grant_principals" {
  description = "Principals to grant catalog privileges: group names, user emails, or service principal application IDs."
  type        = list(string)
}

variable "catalog_grant_privileges" {
  description = "Catalog-level UC privileges only. Do not use CREATE_TABLE/CREATE_VIEW here (use schema grants)."
  type        = list(string)
  default = [
    "BROWSE",
    "USE_CATALOG",
    "CREATE_SCHEMA",
  ]
}

variable "secret_scope_name" {
  description = "Databricks secret scope name"
  type        = string
}

variable "default_labels" {
  description = "Common labels applied to the bucket and, as custom tags, to clusters and SQL warehouses. GCP label rules apply: lowercase keys and values."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.default_labels :
      can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) && can(regex("^[a-z0-9_-]{0,63}$", v))
    ])
    error_message = "default_labels keys and values must be lowercase letters, digits, '_' or '-' (keys start with a letter, max 63 characters)."
  }
}

variable "cluster_policy_config_file" {
  description = "Path to cluster policy YAML config"
  type        = string
}

variable "cluster_config_file" {
  description = "Path to cluster YAML config"
  type        = string
}

variable "sql_warehouse_config_file" {
  description = "Path to SQL warehouse YAML config"
  type        = string
}
