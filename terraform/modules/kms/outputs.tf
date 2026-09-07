output "key_ring_id" {
  value = google_kms_key_ring.this.id
}

output "key_ids" {
  description = "Map of purpose (gke, cloudsql, secrets, artifact) to full crypto key id."
  value       = { for k, v in google_kms_crypto_key.this : k => v.id }
}

output "gke_key_id" {
  value = google_kms_crypto_key.this["gke"].id
}

output "cloudsql_key_id" {
  value = google_kms_crypto_key.this["cloudsql"].id
}

output "secrets_key_id" {
  value = google_kms_crypto_key.this["secrets"].id
}

output "artifact_key_id" {
  value = google_kms_crypto_key.this["artifact"].id
}

output "storage_key_id" {
  value = google_kms_crypto_key.this["storage"].id
}
