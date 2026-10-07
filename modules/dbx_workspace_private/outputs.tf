output "workspace_id" {
  value = module.workspace.workspace_id
}

output "workspace_url" {
  value = module.workspace.workspace_url
}

output "workspace_name" {
  value = module.workspace.workspace_name
}

output "network_name" {
  value = module.network.network_name
}

output "node_subnet_name" {
  value = module.network.node_subnet_name
}

output "psc_endpoint_ips" {
  value = module.network.psc_endpoint_ips
}

output "psc_dns_records" {
  value = try(module.private_dns[0].dns_records, {})
}
