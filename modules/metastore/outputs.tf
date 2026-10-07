output "metastore_id" {
  description = "Unity Catalog metastore ID (UUID)."
  value       = databricks_metastore.this.id
}

output "metastore_name" {
  value = databricks_metastore.this.name
}

output "data_access_service_account" {
  description = "Databricks-managed GCP service account for the metastore storage root (null without storage_root)."
  value       = try(databricks_metastore_data_access.default[0].databricks_gcp_service_account[0].email, null)
}
