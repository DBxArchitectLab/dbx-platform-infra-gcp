variable "databricks_account_id" {
  type = string
}

variable "gcp_project_id" {
  type        = string
  description = "GCP project for the generated google provider."
}

variable "metastore_name" {
  type = string
}

variable "region" {
  type        = string
  description = "GCP region for the metastore (e.g. us-central1). Also used by the generated google provider."
}

variable "storage_root" {
  type        = string
  default     = null
  description = "Optional gs:// URI for metastore-level managed storage. Leave null (recommended) so each catalog sets its own storage root."

  validation {
    condition     = var.storage_root == null || can(regex("^gs://[^/]+", var.storage_root))
    error_message = "storage_root must be a gs://<bucket>[/<path>] URI."
  }
}

variable "force_destroy" {
  type        = bool
  default     = false
  description = "Allow Terraform to delete the metastore even if it is not empty."
}

variable "owner" {
  type        = string
  default     = null
  description = "Optional Unity Catalog owner for the metastore."
}

variable "metastore_data_access_name" {
  type        = string
  default     = "default"
  description = "Name for the default metastore data access configuration (only created with storage_root)."
}
