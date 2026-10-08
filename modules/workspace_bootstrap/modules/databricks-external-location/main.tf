locals {
  external_url = "gs://${var.bucket_name}/"
  # Unity Catalog owners can manage the object; without this, grant-only MANAGE may apply after EL updates in the same run and Terraform still fails to modify the location.
  external_location_owner = coalesce(var.external_location_owner, var.external_location_grant_principals[0])
}

# On GCP the storage credential is backed by a service account that Databricks creates and manages; the
# bucket grants it access below.
resource "databricks_storage_credential" "this" {
  name = var.storage_credential_name

  # Required when the credential is bound to external locations (Unity Catalog API otherwise rejects in-place updates).
  force_update = true
  # Only usable from this environment's workspace, which is bound automatically.
  isolation_mode = "ISOLATION_MODE_ISOLATED"

  databricks_gcp_service_account {}
}

locals {
  credential_service_account = databricks_storage_credential.this.databricks_gcp_service_account[0].email
}

# Databricks creates the credential's service account in its own project when the credential is created; GCP IAM
# can take a minute or more to see a new service account, and bindings made before that fail with
# "Service account ... does not exist". The trigger re-runs the wait if the credential (and its account) is replaced.
resource "time_sleep" "service_account_propagation" {
  create_duration = "90s"

  triggers = {
    service_account = local.credential_service_account
  }
}

# Read/write access to the bucket: object read/write plus bucket metadata (needed to list and validate).
resource "google_storage_bucket_iam_member" "object_admin" {
  bucket = var.bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${time_sleep.service_account_propagation.triggers["service_account"]}"
}

resource "google_storage_bucket_iam_member" "bucket_reader" {
  bucket = var.bucket_name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${time_sleep.service_account_propagation.triggers["service_account"]}"
}

# Bucket IAM changes take a few seconds to apply; creating the external location too early fails validation.
resource "time_sleep" "iam_propagation" {
  create_duration = "30s"

  depends_on = [
    google_storage_bucket_iam_member.object_admin,
    google_storage_bucket_iam_member.bucket_reader,
  ]
}

resource "databricks_external_location" "this" {
  name            = var.external_location_name
  url             = local.external_url
  credential_name = databricks_storage_credential.this.name
  comment         = "Bootstrap external location."
  owner           = local.external_location_owner
  force_update    = true
  isolation_mode  = "ISOLATION_MODE_ISOLATED"

  depends_on = [time_sleep.iam_propagation]
}

# The metastore is shared by dev/uat/prod. ISOLATION_MODE_ISOLATED binds the credential and the location to the
# workspace that creates them (this environment's) automatically. Explicit bindings to the same workspace used to
# live here; they were redundant and broke destroy (removed first, they left the objects inaccessible). Forget them
# without unbinding the workspace.
removed {
  from = databricks_workspace_binding.storage_credential

  lifecycle {
    destroy = false
  }
}

removed {
  from = databricks_workspace_binding.external_location

  lifecycle {
    destroy = false
  }
}

resource "databricks_grants" "external_location" {
  count = var.enable_external_location_grants ? 1 : 0

  external_location = databricks_external_location.this.name

  dynamic "grant" {
    for_each = toset(var.external_location_grant_principals)
    content {
      principal  = grant.value
      privileges = var.external_location_grant_privileges
    }
  }

  depends_on = [databricks_external_location.this]
}
