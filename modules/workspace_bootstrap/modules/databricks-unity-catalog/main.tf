locals {
  # Managed tables for this catalog; must be under an external location + credential (see workspace_bootstrap order).
  catalog_storage_root = "gs://${var.bucket_name}/${var.catalog_managed_prefix}/${var.catalog_name}/"
}

resource "databricks_catalog" "default" {
  name         = var.catalog_name
  comment      = "Default Unity Catalog bootstrap catalog."
  storage_root = local.catalog_storage_root

  # Delete even if the catalog still contains schemas or tables.
  force_destroy = var.force_destroy

  # The metastore is shared by dev/uat/prod; without isolation the catalog shows up in every workspace.
  # ISOLATED binds the catalog to the workspace that creates it (this environment's) automatically.
  isolation_mode = "ISOLATED"
}

# An explicit binding to the same workspace used to live here. It was redundant with the automatic binding and
# broke destroy: removing it first left the catalog inaccessible, so deleting its grants and the catalog failed
# ("Catalog ... is not accessible in current workspace"). Forget it without unbinding the workspace.
# Note: only `apply` honors this block; `destroy` still destroys a binding that is in state. A stack deployed with
# the old binding must run `apply` once before `destroy` (DEPLOYMENT.md, Troubleshooting).
removed {
  from = databricks_workspace_binding.catalog

  lifecycle {
    destroy = false
  }
}

resource "databricks_grants" "catalog" {
  count = var.enable_catalog_grants ? 1 : 0

  catalog = databricks_catalog.default.name

  dynamic "grant" {
    for_each = toset(var.catalog_grant_principals)
    content {
      principal  = grant.value
      privileges = var.catalog_grant_privileges
    }
  }

  depends_on = [databricks_catalog.default]
}
