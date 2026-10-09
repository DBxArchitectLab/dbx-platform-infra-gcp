# Validation notebook, deployed to every environment's workspace. The notebook source is the same everywhere; the
# JSON file next to it holds this environment's expected values, taken from the same inputs and module outputs that
# provisioned the resources it checks.
locals {
  validation_notebook_path = "/Shared/platform/workspace-bootstrap-validation"

  validation_config = {
    environment    = try(var.default_labels.environment, null)
    workspace_name = try(var.default_labels.workspace, null)
    workspace_id   = var.workspace_id
    workspace_url  = var.databricks_host
    region         = var.region
    metastore_id   = var.metastore_id == "" ? null : var.metastore_id
    admin_group    = var.platform_admin_group_name

    catalog = {
      name             = module.unity_catalog.catalog_name
      storage_root     = module.unity_catalog.catalog_storage_root
      grant_principals = var.enable_catalog_grants ? var.catalog_grant_principals : []
      grant_privileges = var.catalog_grant_privileges
    }

    storage_credential = {
      name            = module.external_location.storage_credential_name
      service_account = module.external_location.storage_credential_service_account
    }

    external_location = {
      name             = module.external_location.external_location_name
      url              = module.external_location.external_location_url
      grant_principals = var.enable_external_location_grants ? var.external_location_grant_principals : []
      grant_privileges = var.external_location_grant_privileges
    }

    cluster_policies = sort(keys(module.cluster_policy.cluster_policy_ids))
    secret_scope     = module.secret_scope.secret_scope_name
  }
}

resource "databricks_notebook" "bootstrap_validation" {
  path   = local.validation_notebook_path
  source = "${path.module}/notebooks/workspace-bootstrap-validation.py"
}

resource "databricks_workspace_file" "bootstrap_validation_config" {
  path           = "${local.validation_notebook_path}.json"
  content_base64 = base64encode(jsonencode(local.validation_config))
}
