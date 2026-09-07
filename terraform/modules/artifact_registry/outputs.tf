output "repository_url" {
  description = "Registry host/path images are pushed to and pulled from."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.buzz.repository_id}"
}

output "repository_id" {
  value = google_artifact_registry_repository.buzz.repository_id
}

output "attestor_name" {
  value = var.enable_binary_authorization ? google_binary_authorization_attestor.mirror[0].name : ""
}

output "attestor_note" {
  value = var.enable_binary_authorization ? google_container_analysis_note.attestor[0].name : ""
}
