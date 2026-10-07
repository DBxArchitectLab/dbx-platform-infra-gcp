# GCS bucket for the Unity Catalog external location and the catalog's managed storage.
# Data is encrypted at rest with Google-managed keys by default.
resource "google_storage_bucket" "this" {
  project       = var.gcp_project_id
  name          = var.bucket_name
  location      = var.location
  storage_class = "STANDARD"
  force_destroy = var.force_destroy
  labels        = var.labels

  # IAM-only access control (no object ACLs) and no public access.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
}
