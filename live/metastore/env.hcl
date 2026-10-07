locals {
  common = yamldecode(file("${get_terragrunt_dir()}/../common.yaml"))
  config = yamldecode(file("${get_terragrunt_dir()}/config.yaml"))
}

inputs = {
  # Supplied as an environment variable (GitHub environment secret in CI).
  databricks_account_id = get_env("DATABRICKS_ACCOUNT_ID")
  gcp_project_id        = try(local.config.gcp_project_id, local.common.gcp_project_id)
}
