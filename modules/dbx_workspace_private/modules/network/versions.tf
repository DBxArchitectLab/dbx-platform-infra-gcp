terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
    databricks = {
      source                = "databricks/databricks"
      configuration_aliases = [databricks.account]
    }
  }
}
