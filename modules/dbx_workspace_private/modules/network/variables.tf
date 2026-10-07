variable "databricks_account_id" {
  type = string
}

variable "gcp_project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_name" {
  type = string
}

variable "node_subnet_cidr" {
  type        = string
  description = "Cluster VM subnet (netmask between /29 and /9)."

  validation {
    condition = (
      can(cidrhost(var.node_subnet_cidr, 0)) &&
      try(tonumber(split("/", var.node_subnet_cidr)[1]) >= 9 && tonumber(split("/", var.node_subnet_cidr)[1]) <= 29, false)
    )
    error_message = "node_subnet_cidr must be a CIDR with a netmask between /9 and /29."
  }
}

variable "psc_subnet_cidr" {
  type        = string
  default     = null
  description = "Small subnet for the Private Service Connect endpoints. Used only when psc_enabled."
}

variable "nat_enabled" {
  type = bool
}

variable "psc_enabled" {
  type = bool
}

variable "public_access_enabled" {
  type = bool
}

variable "workspace_service_attachment" {
  type    = string
  default = null
}

variable "relay_service_attachment" {
  type    = string
  default = null
}
