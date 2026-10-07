output "cluster_policy_ids" {
  value = module.cluster_policy.cluster_policy_ids
}

#output "cluster_ids" {
#  value = module.cluster.cluster_ids
#}
#
#output "sql_warehouse_ids" {
#  value = module.sql_warehouse.sql_warehouse_ids
#}

output "bucket_name" {
  description = "GCS bucket created for Unity Catalog"
  value       = module.gcs_storage.bucket_name
}

output "bucket_url" {
  value = module.gcs_storage.bucket_url
}

output "uc_storage_service_account" {
  description = "Databricks-managed GCP service account Unity Catalog uses to access the bucket"
  value       = module.external_location.storage_credential_service_account
}

output "unity_catalog_id" {
  value = module.unity_catalog.catalog_id
}

output "unity_catalog_name" {
  value = module.unity_catalog.catalog_name
}

output "unity_catalog_storage_root" {
  value = module.unity_catalog.catalog_storage_root
}

output "unity_catalog_external_location_name" {
  value = module.external_location.external_location_name
}

output "unity_catalog_external_location_url" {
  value = module.external_location.external_location_url
}

output "unity_catalog_storage_credential_name" {
  value = module.external_location.storage_credential_name
}

output "secret_scope_name" {
  value = module.secret_scope.secret_scope_name
}
