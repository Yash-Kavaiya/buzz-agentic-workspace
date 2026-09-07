output "secret_ids" {
  description = "Map of logical name to Secret Manager secret_id, for buzzctl and the ExternalSecret template."
  value = merge(
    { for k, v in google_secret_manager_secret.managed : k => v.secret_id },
    { for k, v in google_secret_manager_secret.externally_populated : k => v.secret_id },
  )
}

output "externally_populated_secret_ids" {
  description = "Secrets buzzctl must populate before the first deploy."
  value       = [for v in google_secret_manager_secret.externally_populated : v.secret_id]
}

output "prefix" {
  description = "Secret name prefix; the Helm ExternalSecret builds remote keys from it."
  value       = var.name_prefix
}
