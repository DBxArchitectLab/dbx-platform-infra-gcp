resource "databricks_metastore" "this" {
  provider = databricks.account

  name          = var.metastore_name
  storage_root  = var.storage_root
  region        = var.region
  force_destroy = var.force_destroy
  owner         = var.owner
}

locals {
  data_access_enabled = var.storage_root != null && var.storage_root != ""
  # Bucket name from "gs://<bucket>/<path>".
  storage_root_bucket = local.data_access_enabled ? regex("^gs://([^/]+)", var.storage_root)[0] : null
}

# Metastore-level storage credential, backed by a GCP service account that Databricks creates and manages.
resource "databricks_metastore_data_access" "default" {
  count = local.data_access_enabled ? 1 : 0

  provider = databricks.account

  metastore_id = databricks_metastore.this.id
  name         = var.metastore_data_access_name

  databricks_gcp_service_account {}

  is_default = true
}

# GCP IAM can take a minute or more to see the service account Databricks just created; bindings made before that
# fail with "Service account ... does not exist".
resource "time_sleep" "service_account_propagation" {
  count = local.data_access_enabled ? 1 : 0

  create_duration = "90s"

  triggers = {
    service_account = databricks_metastore_data_access.default[0].databricks_gcp_service_account[0].email
  }
}

# Read/write access to the storage root bucket for the Databricks-managed service account.
resource "google_storage_bucket_iam_member" "data_access" {
  for_each = local.data_access_enabled ? toset(["roles/storage.objectAdmin", "roles/storage.legacyBucketReader"]) : toset([])

  bucket = local.storage_root_bucket
  role   = each.key
  member = "serviceAccount:${time_sleep.service_account_propagation[0].triggers["service_account"]}"
}
