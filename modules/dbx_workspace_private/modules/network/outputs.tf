output "network_name" {
  value = google_compute_network.this.name
}

output "network_self_link" {
  value = google_compute_network.this.self_link
}

output "node_subnet_name" {
  value = google_compute_subnetwork.nodes.name
}

output "network_id" {
  value = databricks_mws_networks.this.network_id
}

output "private_access_settings_id" {
  value = var.psc_enabled ? databricks_mws_private_access_settings.this[0].private_access_settings_id : null
}

output "psc_endpoint_ips" {
  description = "Internal IPs of the PSC endpoints (workspace and relay); empty without PSC."
  value       = { for k, v in google_compute_address.psc : k => v.address }
}
