locals {
  common = yamldecode(file("${get_parent_terragrunt_dir()}/common.yaml"))

  # Terraform state lives in a GCS bucket in the deployment GCP project. The project ID suffix keeps the
  # bucket name globally unique. The gcs backend locks state natively, so no lock table is needed.
  state_project  = local.common.gcp_project_id
  state_bucket   = "${local.common.state.bucket_prefix}-${local.common.gcp_project_id}"
  state_location = local.common.state.location
}

remote_state {
  backend = "gcs"

  generate = {
    path      = "backend.generated.tf"
    if_exists = "overwrite"
  }

  config = {
    bucket = local.state_bucket
    prefix = path_relative_to_include()

    # Used by Terragrunt only if it has to create the bucket; the bucket is normally created up front.
    project  = local.state_project
    location = local.state_location
  }
}

generate "providers" {
  path      = "providers.generated.tf"
  if_exists = "overwrite"
  contents  = <<EOF
# Credentials come from Application Default Credentials: Workload Identity Federation in CI,
# `gcloud auth application-default login` (optionally with GOOGLE_IMPERSONATE_SERVICE_ACCOUNT) locally.
provider "google" {
  project = var.gcp_project_id
  region  = var.region
}

# Account-level provider. Databricks on GCP only accepts Google-issued OIDC tokens for account APIs: the
# provider impersonates the GCP service account in DATABRICKS_GOOGLE_SERVICE_ACCOUNT (an account admin).
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.gcp.databricks.com"
  account_id = var.databricks_account_id
}
EOF
}
