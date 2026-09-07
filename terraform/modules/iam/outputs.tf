output "node_service_account" {
  value = google_service_account.node.email
}

output "relay_service_account" {
  value = google_service_account.relay.email
}

output "external_secrets_service_account" {
  value = google_service_account.external_secrets.email
}

output "minio_backup_service_account" {
  value = google_service_account.minio_backup.email
}

output "relay_iam_db_user" {
  description = "Feed to the cloudsql module as iam_database_user so --auto-iam-authn works."
  value       = google_service_account.relay.email
}
