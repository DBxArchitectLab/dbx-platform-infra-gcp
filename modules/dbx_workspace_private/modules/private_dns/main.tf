# DNS for back-end Private Service Connect. A private gcp.databricks.com zone, visible only to this VPC,
# points the workspace and relay host names at the PSC endpoint IPs, so cluster traffic to the control
# plane goes through the endpoints instead of Cloud NAT.
locals {
  # "https://<workspace-id>.<n>.gcp.databricks.com" -> "<workspace-id>.<n>.gcp.databricks.com"
  workspace_host = trimsuffix(trimprefix(var.workspace_url, "https://"), "/")

  records = {
    workspace = { name = "${local.workspace_host}.", ip = var.workspace_endpoint_ip }
    dataplane = { name = "dp-${local.workspace_host}.", ip = var.workspace_endpoint_ip }
    psc       = { name = "${var.region}.psc.gcp.databricks.com.", ip = var.workspace_endpoint_ip }
    relay     = { name = "tunnel.${var.region}.gcp.databricks.com.", ip = var.relay_endpoint_ip }
  }
}

resource "google_dns_managed_zone" "databricks" {
  project     = var.gcp_project_id
  name        = "${var.vpc_name}-databricks"
  dns_name    = "gcp.databricks.com."
  description = "Databricks Private Service Connect endpoints for ${var.vpc_name}"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = var.network_self_link
    }
  }
}

resource "google_dns_record_set" "this" {
  for_each = local.records

  project      = var.gcp_project_id
  managed_zone = google_dns_managed_zone.databricks.name
  name         = each.value.name
  type         = "A"
  ttl          = 300
  rrdatas      = [each.value.ip]
}
