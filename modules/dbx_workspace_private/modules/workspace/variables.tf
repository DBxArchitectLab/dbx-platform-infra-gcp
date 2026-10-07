variable "databricks_account_id" {
  type = string
}

variable "gcp_project_id" {
  type = string
}

variable "workspace_name" {
  type = string
}

variable "region" {
  type = string
}

variable "network_id" {
  type = string
}

variable "private_access_settings_id" {
  type    = string
  default = null
}
