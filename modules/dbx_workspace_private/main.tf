module "network" {
  source = "./modules/network"

  providers = {
    databricks.account = databricks.account
  }

  databricks_account_id        = var.databricks_account_id
  gcp_project_id               = var.gcp_project_id
  region                       = var.region
  vpc_name                     = var.vpc_name
  databricks_name_prefix       = var.databricks_name_prefix
  node_subnet_cidr             = var.node_subnet_cidr
  psc_subnet_cidr              = var.psc_subnet_cidr
  nat_enabled                  = var.nat_enabled
  psc_enabled                  = var.psc_enabled
  public_access_enabled        = var.public_access_enabled
  workspace_service_attachment = var.workspace_service_attachment
  relay_service_attachment     = var.relay_service_attachment
}

# Destroy only: Databricks deletes a GCP workspace asynchronously, and its network configuration (and PSC
# endpoints, private access settings) can't be deleted until the workspace is fully gone ("Cannot delete a network
# while it is attached to a workspace"). Destroy order is workspace → this wait → network.
resource "time_sleep" "workspace_deletion" {
  destroy_duration = "10m"

  depends_on = [module.network]
}

module "workspace" {
  source = "./modules/workspace"

  providers = {
    databricks.account = databricks.account
  }

  databricks_account_id      = var.databricks_account_id
  gcp_project_id             = var.gcp_project_id
  workspace_name             = var.workspace_name
  region                     = var.region
  network_id                 = module.network.network_id
  private_access_settings_id = module.network.private_access_settings_id

  depends_on = [time_sleep.workspace_deletion]
}

# Private DNS for back-end Private Service Connect; the record names depend on the workspace URL.
module "private_dns" {
  source = "./modules/private_dns"
  count  = var.psc_enabled ? 1 : 0

  gcp_project_id        = var.gcp_project_id
  region                = var.region
  vpc_name              = var.vpc_name
  network_self_link     = module.network.network_self_link
  workspace_url         = module.workspace.workspace_url
  workspace_endpoint_ip = module.network.psc_endpoint_ips["workspace"]
  relay_endpoint_ip     = module.network.psc_endpoint_ips["relay"]
}

module "metastore_assignment" {
  source = "./modules/metastore_assignment"

  providers = {
    databricks.account = databricks.account
  }

  workspace_id = module.workspace.workspace_id
  metastore_id = var.metastore_id
}

module "workspace_group_assignment" {
  source = "./modules/workspace_group_assignment"

  providers = {
    databricks.account = databricks.account
  }

  workspace_id              = module.workspace.workspace_id
  platform_admin_group_name = var.platform_admin_group_name

  # Account-level permission assignment needs identity federation, which Unity Catalog assignment enables.
  depends_on = [module.metastore_assignment]
}
