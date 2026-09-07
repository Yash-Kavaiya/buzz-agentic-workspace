output "cluster_name" {
  value = google_container_cluster.this.name
}

output "cluster_id" {
  value = google_container_cluster.this.id
}

output "cluster_endpoint" {
  value     = google_container_cluster.this.endpoint
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "location" {
  value = google_container_cluster.this.location
}

output "workload_identity_pool" {
  value = "${var.project_id}.svc.id.goog"
}

output "get_credentials_command" {
  description = "What buzzctl runs to populate kubeconfig."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --region ${var.region} --project ${var.project_id}"
}

output "node_pool_names" {
  value = [for p in google_container_node_pool.this : p.name]
}
