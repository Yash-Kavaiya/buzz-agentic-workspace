output "host" {
  value = google_redis_instance.this.host
}

output "port" {
  value = google_redis_instance.this.port
}

output "auth_string" {
  description = "Written to Secret Manager as part of REDIS_URL. Never logged."
  value       = google_redis_instance.this.auth_string
  sensitive   = true
}

output "server_ca_cert" {
  description = <<-EOT
    PEM of the Google-managed CA that signs the instance certificate. Empty when
    transit encryption is disabled. The Helm chart mounts this so the relay's
    rustls trust store can verify a rediss:// handshake.
  EOT
  value     = var.transit_encryption_enabled ? try(google_redis_instance.this.server_ca_certs[0].cert, "") : ""
  sensitive = false
}

output "redis_url" {
  description = "Full connection URL with credentials. Consumed only by the secrets module."
  value = format(
    "%s://:%s@%s:%d",
    var.transit_encryption_enabled ? "rediss" : "redis",
    google_redis_instance.this.auth_string,
    google_redis_instance.this.host,
    google_redis_instance.this.port,
  )
  sensitive = true
}

output "transit_encryption_enabled" {
  value = var.transit_encryption_enabled
}
