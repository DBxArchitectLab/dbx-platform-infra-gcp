terraform {
  required_version = ">= 1.10.0"

  required_providers {
    google = {
      source = "hashicorp/google"
    }
    databricks = {
      source = "databricks/databricks"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}
