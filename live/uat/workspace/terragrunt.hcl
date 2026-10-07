include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  config = local.env.locals.config
}

terraform {
  source = "../../../modules/dbx_workspace_private"
}

inputs = merge(
  local.env.inputs,
  {
    workspace_name = local.config.workspace_name
    region         = local.config.region

    vpc_name         = local.config.network.vpc_name
    node_subnet_cidr = local.config.network.node_subnet_cidr
    psc_subnet_cidr  = try(local.config.network.psc_subnet_cidr, null)
    nat_enabled      = try(local.config.network.nat_enabled, true)

    psc_enabled                  = try(local.config.private_service_connect.enabled, false)
    public_access_enabled        = try(local.config.private_service_connect.public_access_enabled, true)
    workspace_service_attachment = try(local.config.private_service_connect.workspace_service_attachment, null)
    relay_service_attachment     = try(local.config.private_service_connect.relay_service_attachment, null)

    metastore_id              = get_env("DATABRICKS_METASTORE_ID")
    platform_admin_group_name = local.config.identity.platform_admin_group_name
  }
)
