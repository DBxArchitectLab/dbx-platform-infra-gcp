terraform {
  required_version = ">= 1.10.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }

    databricks = {
      source  = "databricks/databricks"
      version = ">= 1.105.0"
    }
  }
}
