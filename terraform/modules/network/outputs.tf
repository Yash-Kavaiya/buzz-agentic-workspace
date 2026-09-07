output "network_id" {
  value = google_compute_network.vpc.id
}

output "network_name" {
  value = google_compute_network.vpc.name
}

output "network_self_link" {
  value = google_compute_network.vpc.self_link
}

output "subnet_id" {
  value = google_compute_subnetwork.gke.id
}

output "subnet_name" {
  value = google_compute_subnetwork.gke.name
}

output "pods_range_name" {
  value = one([for r in google_compute_subnetwork.gke.secondary_ip_range : r.range_name if endswith(r.range_name, "-pods")])
}

output "services_range_name" {
  value = one([for r in google_compute_subnetwork.gke.secondary_ip_range : r.range_name if endswith(r.range_name, "-services")])
}

output "node_tag" {
  description = "Network tag every GKE node carries; firewall rules key off it."
  value       = "${var.name_prefix}-node"
}

output "private_service_connection" {
  description = "Depend on this from cloudsql/memorystore so private IPs are only allocated after peering exists."
  value       = google_service_networking_connection.psa.id
}

output "master_cidr" {
  value = var.master_cidr
}
