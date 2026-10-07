locals {
  node_subnet_name = "${var.vpc_name}-nodes"
}

# --- VPC and subnets --------------------------------------------------------------------------------

resource "google_compute_network" "this" {
  project                 = var.gcp_project_id
  name                    = var.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# Cluster VM subnet. Databricks on GCP uses one regional subnet per workspace (netmask /29 to /9).
# Private Google Access keeps GCS and other Google API traffic (root bucket, Unity Catalog storage,
# runtime artifacts) on Google's network.
resource "google_compute_subnetwork" "nodes" {
  project                  = var.gcp_project_id
  name                     = local.node_subnet_name
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.node_subnet_cidr
  private_ip_google_access = true
}

# Subnet for the Private Service Connect endpoints.
resource "google_compute_subnetwork" "psc" {
  count = var.psc_enabled ? 1 : 0

  project                  = var.gcp_project_id
  name                     = "${var.vpc_name}-psc"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.psc_subnet_cidr
  private_ip_google_access = true
}

# --- Firewall ---------------------------------------------------------------------------------------

# Databricks doesn't create firewall rules in a customer-managed VPC: cluster nodes must be allowed to talk
# to each other. The name follows the Databricks convention (db-<subnet-name>-ingress). Egress is open by
# default in a GCP VPC.
resource "google_compute_firewall" "intra_subnet" {
  project     = var.gcp_project_id
  name        = "db-${local.node_subnet_name}-ingress"
  network     = google_compute_network.this.id
  description = "All traffic between Databricks cluster nodes"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.node_subnet_cidr]

  allow {
    protocol = "all"
  }
}

# --- Internet egress (Cloud NAT) --------------------------------------------------------------------

resource "google_compute_router" "this" {
  count = var.nat_enabled ? 1 : 0

  project = var.gcp_project_id
  name    = "${var.vpc_name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count = var.nat_enabled ? 1 : 0

  project                            = var.gcp_project_id
  name                               = "${var.vpc_name}-nat"
  router                             = google_compute_router.this[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Private Service Connect endpoints --------------------------------------------------------------

# Back-end PSC: workspace REST API and secure cluster connectivity relay.
resource "google_compute_address" "psc" {
  for_each = var.psc_enabled ? toset(["workspace", "relay"]) : toset([])

  project      = var.gcp_project_id
  name         = "${var.vpc_name}-psc-${each.key}"
  region       = var.region
  subnetwork   = google_compute_subnetwork.psc[0].id
  address_type = "INTERNAL"
}

resource "google_compute_forwarding_rule" "psc" {
  for_each = var.psc_enabled ? {
    workspace = var.workspace_service_attachment
    relay     = var.relay_service_attachment
  } : {}

  project    = var.gcp_project_id
  name       = "${var.vpc_name}-psc-${each.key}"
  region     = var.region
  network    = google_compute_network.this.id
  ip_address = google_compute_address.psc[each.key].id
  target     = each.value
  # An empty scheme is required for a PSC endpoint that targets a published service attachment.
  load_balancing_scheme = ""
}

# --- Databricks account registrations ---------------------------------------------------------------

resource "databricks_mws_vpc_endpoint" "this" {
  for_each = google_compute_forwarding_rule.psc
  provider = databricks.account

  account_id        = var.databricks_account_id
  vpc_endpoint_name = "${var.vpc_name}-${each.key}"

  gcp_vpc_endpoint_info {
    project_id        = var.gcp_project_id
    psc_endpoint_name = each.value.name
    endpoint_region   = var.region
  }
}

resource "databricks_mws_networks" "this" {
  provider = databricks.account

  account_id   = var.databricks_account_id
  network_name = "${var.vpc_name}-network"

  gcp_network_info {
    network_project_id = var.gcp_project_id
    vpc_id             = google_compute_network.this.name
    subnet_id          = google_compute_subnetwork.nodes.name
    subnet_region      = var.region
  }

  dynamic "vpc_endpoints" {
    for_each = var.psc_enabled ? [1] : []
    content {
      rest_api        = [databricks_mws_vpc_endpoint.this["workspace"].vpc_endpoint_id]
      dataplane_relay = [databricks_mws_vpc_endpoint.this["relay"].vpc_endpoint_id]
    }
  }

  lifecycle {
    precondition {
      condition     = var.nat_enabled || var.psc_enabled
      error_message = "Clusters need a path to the Databricks control plane: enable nat_enabled, psc_enabled, or both."
    }

    precondition {
      condition     = !var.psc_enabled || (var.psc_subnet_cidr != null && var.workspace_service_attachment != null && var.relay_service_attachment != null)
      error_message = "With psc_enabled, set psc_subnet_cidr, workspace_service_attachment and relay_service_attachment."
    }
  }

  depends_on = [
    google_compute_firewall.intra_subnet,
    google_compute_router_nat.this,
  ]
}

resource "databricks_mws_private_access_settings" "this" {
  count    = var.psc_enabled ? 1 : 0
  provider = databricks.account

  private_access_settings_name = "${var.vpc_name}-pas"
  region                       = var.region
  public_access_enabled        = var.public_access_enabled
  private_access_level         = "ACCOUNT"
}
