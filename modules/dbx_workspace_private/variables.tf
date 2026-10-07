variable "databricks_account_id" {
  type = string
}

variable "gcp_project_id" {
  type        = string
  description = "GCP project for the workspace, its VPC and the resources Databricks creates (root bucket, compute service account)."
}

variable "region" {
  type        = string
  description = "GCP region for the workspace and its subnet (e.g. us-central1)."
}

variable "workspace_name" {
  type = string
}

variable "vpc_name" {
  type = string
}

variable "databricks_name_prefix" {
  type        = string
  default     = null
  description = "Prefix for Databricks account objects (network, VPC endpoints, private access settings); max 22 characters. Defaults to vpc_name without a leading \"vpc-\"."
}

variable "node_subnet_cidr" {
  type        = string
  description = "Cluster VM subnet (netmask between /29 and /9)."
}

variable "psc_subnet_cidr" {
  type        = string
  default     = null
  description = "Subnet for the Private Service Connect endpoints. Used only when psc_enabled."
}

variable "nat_enabled" {
  type        = bool
  default     = true
  description = "Create a Cloud Router and Cloud NAT so clusters can reach the internet (PyPI, Maven, external APIs) and, without PSC, the Databricks control plane."
}

variable "psc_enabled" {
  type        = bool
  default     = false
  description = "Back-end Private Service Connect (REST API + secure cluster connectivity relay). Requires the Databricks Enterprise tier."
}

variable "public_access_enabled" {
  type        = bool
  default     = true
  description = "Allow access to the workspace from the public internet. Only applies when psc_enabled."
}

variable "workspace_service_attachment" {
  type        = string
  default     = null
  description = "Regional Databricks workspace (REST API) PSC service attachment URI."
}

variable "relay_service_attachment" {
  type        = string
  default     = null
  description = "Regional Databricks secure cluster connectivity relay PSC service attachment URI."
}

variable "metastore_id" {
  type = string
}

variable "platform_admin_group_name" {
  type = string
}
