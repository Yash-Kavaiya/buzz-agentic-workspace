output "gateway_ip_name" {
  description = "Named address the Gateway binds to via networking.gke.io/addresses."
  value       = google_compute_global_address.gateway.name
}

output "gateway_ip_address" {
  value = google_compute_global_address.gateway.address
}

output "certificate_map_name" {
  description = "Referenced by the Gateway's networking.gke.io/certmap annotation."
  value       = google_certificate_manager_certificate_map.this.name
}

output "security_policy_name" {
  description = "Referenced by GCPBackendPolicy.spec.default.securityPolicy."
  value       = google_compute_security_policy.this.name
}

output "relay_hostname" {
  value = var.relay_hostname
}

output "admin_hostname" {
  value = var.admin_hostname
}

output "relay_url" {
  description = "Exactly what goes into the chart's relayUrl."
  value       = "wss://${var.relay_hostname}"
}

output "dns_authorization_records" {
  description = "Create these manually if the zone is managed outside this project."
  value = {
    relay = google_certificate_manager_dns_authorization.relay.dns_resource_record
    admin = google_certificate_manager_dns_authorization.admin.dns_resource_record
  }
}
