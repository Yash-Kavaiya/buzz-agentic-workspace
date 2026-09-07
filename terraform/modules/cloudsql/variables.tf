variable "project_id" {
  description = "GCP project that hosts this environment."
  type        = string
}

variable "region" {
  description = "Primary region. All regional resources land here."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix for this environment, e.g. buzz-prod."
  type        = string
}

variable "network_id" {
  description = "VPC the instance gets its private IP in."
  type        = string
}

variable "private_service_connection" {
  description = "Depend on the PSA peering so the private IP allocation cannot race it."
  type        = string
}

variable "database_version" {
  description = "Buzz targets Postgres 17 (see the upstream .env.example)."
  type        = string
  default     = "POSTGRES_17"
}

variable "tier" {
  description = "Machine tier. Size from expected concurrent relay connections; the relay pools per replica."
  type        = string
  default     = "db-custom-4-16384"
}

variable "disk_size_gb" {
  description = "Provisioned storage in GiB."
  type        = number
  default     = 100
}

variable "availability_type" {
  description = "REGIONAL gives synchronous replication and automatic failover. ZONAL is dev only."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "ZONAL"], var.availability_type)
    error_message = "availability_type must be REGIONAL or ZONAL."
  }
}

variable "database_name" {
  description = "Postgres database Buzz uses."
  type        = string
  default     = "buzz"
}

variable "app_user" {
  description = "Built-in Postgres role used when IAM authentication is not in play."
  type        = string
  default     = "buzz"
}

variable "iam_database_user" {
  description = <<-EOT
    Service-account email registered as a Cloud SQL IAM user. When the relay
    runs the Auth Proxy with --auto-iam-authn this is the role it connects as,
    and no database password exists at all.
  EOT
  type        = string
  default     = ""
}

variable "backup_retention_days" {
  description = "How many automated backups to retain."
  type        = number
  default     = 30
}

variable "transaction_log_retention_days" {
  description = "Point-in-time recovery window. Cloud SQL caps this at 35."
  type        = number
  default     = 7

  validation {
    condition     = var.transaction_log_retention_days >= 1 && var.transaction_log_retention_days <= 35
    error_message = "transaction_log_retention_days must be between 1 and 35."
  }
}

variable "kms_key_id" {
  description = "CMEK for data and backups. Empty uses Google-managed keys."
  type        = string
  default     = ""
}

variable "read_replica_enabled" {
  description = <<-EOT
    Create a read replica and hand its URL to the relay as READ_DATABASE_URL.
    The relay routes only read-safe operations there; leave off until read load
    actually warrants it, since it doubles the instance bill.
  EOT
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Refuse to delete this resource through Terraform."
  type        = bool
  default     = true
}

variable "max_connections" {
  description = <<-EOT
    Must exceed (relay replicas x pool size) plus headroom for migrations and
    buzz-admin. The relay defaults to a writer pool of 50 per replica.
  EOT
  type        = string
  default     = "400"
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
