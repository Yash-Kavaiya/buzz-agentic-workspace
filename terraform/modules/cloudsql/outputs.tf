output "instance_name" {
  value = google_sql_database_instance.this.name
}

output "connection_name" {
  description = "project:region:instance — what the Cloud SQL Auth Proxy sidecar takes as its argument."
  value       = google_sql_database_instance.this.connection_name
}

output "private_ip_address" {
  value = google_sql_database_instance.this.private_ip_address
}

output "database_name" {
  value = google_sql_database.buzz.name
}

output "app_user" {
  value = google_sql_user.app.name
}

output "app_password" {
  description = "Written to Secret Manager by the secrets module; never rendered into values.yaml."
  value       = random_password.app_user.result
  sensitive   = true
}

output "replica_connection_name" {
  value = var.read_replica_enabled ? google_sql_database_instance.replica[0].connection_name : ""
}

output "replica_private_ip_address" {
  value = var.read_replica_enabled ? google_sql_database_instance.replica[0].private_ip_address : ""
}
