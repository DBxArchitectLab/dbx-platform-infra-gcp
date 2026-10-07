output "external_location_name" {
  value = databricks_external_location.this.name
}

output "external_location_url" {
  value = databricks_external_location.this.url
}

output "storage_credential_name" {
  value = databricks_storage_credential.this.name
}

output "storage_credential_service_account" {
  description = "Databricks-managed GCP service account Unity Catalog uses to access the bucket."
  value       = local.credential_service_account
}
