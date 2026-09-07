variable "project_id" {
  description = "GCP project that hosts this environment."
  type = string
}

variable "region" {
  description = "Primary region. All regional resources land here."
  type = string
}

variable "name_prefix" {
  description = "Resource name prefix for this environment, e.g. buzz-prod."
  type = string
}

variable "network_id" {
  description = "VPC network id the resource attaches to."
  type = string
}

variable "private_service_connection" {
  description = "PSA peering to depend on before allocating a private IP."
  type = string
}

variable "tier" {
  description = "STANDARD_HA gives a replica and automatic failover. BASIC is dev only and loses data on failover."
  type        = string
  default     = "STANDARD_HA"

  validation {
    condition     = contains(["BASIC", "STANDARD_HA"], var.tier)
    error_message = "tier must be BASIC or STANDARD_HA."
  }
}

variable "memory_size_gb" {
  description = <<-EOT
    Buzz uses Redis for pubsub, presence and typing indicators — high churn,
    low residency. 5 GiB is generous for a few thousand connected clients.
  EOT
  type    = number
  default = 5
}

variable "redis_version" {
  description = "Memorystore Redis engine version."
  type    = string
  default = "REDIS_7_2"
}

variable "transit_encryption_enabled" {
  description = <<-EOT
    Enable Memorystore in-transit encryption (the relay then dials rediss://).

    Read this before flipping it on. Memorystore terminates TLS with a
    Google-managed *private* CA that is not in any public trust store. The relay
    links redis with rustls; the connection only succeeds if that CA is present
    in the trust bundle the process reads. The Helm chart mounts the CA from a
    ConfigMap and sets SSL_CERT_FILE/SSL_CERT_DIR for exactly this reason, and
    `buzzctl preflight` proves the handshake before deploy.

    If the handshake cannot be made to work in your environment, the supported
    fallback is AUTH-only on the private VPC (this flag false) — documented in
    docs/90-adr/ADR-005, not silently ignored.
  EOT
  type    = bool
  default = true
}

variable "maintenance_day" {
  description = "Weekday for the managed maintenance window."
  type    = string
  default = "SUNDAY"
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type    = map(string)
  default = {}
}
