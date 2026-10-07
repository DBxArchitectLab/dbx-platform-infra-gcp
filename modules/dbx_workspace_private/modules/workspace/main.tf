# On GCP, Databricks creates the workspace's GCS root bucket and compute service account in the project
# itself, using the permissions of the identity that creates the workspace (there are no credential or
# storage configuration objects, unlike AWS).
resource "databricks_mws_workspaces" "this" {
  provider = databricks.account

  account_id     = var.databricks_account_id
  workspace_name = var.workspace_name
  location       = var.region

  cloud_resource_container {
    gcp {
      project_id = var.gcp_project_id
    }
  }

  network_id                 = var.network_id
  private_access_settings_id = var.private_access_settings_id
}
