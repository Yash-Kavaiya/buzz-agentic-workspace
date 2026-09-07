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

variable "kms_key_id" {
  description = "CMEK for secret payloads. Empty uses Google-managed keys."
  type        = string
  default     = ""
}

variable "accessor_service_account" {
  description = "External Secrets Operator GSA granted read on every secret here."
  type        = string
}

variable "database_url" {
  description = "Composed Postgres DSN. Terraform already holds the password in state, so managing this version here adds no new exposure."
  type        = string
  sensitive   = true
}

variable "read_database_url" {
  description = "Optional read-replica DSN. Empty means the relay keeps all reads on the writer."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_url" {
  description = "Composed Redis URL including the Memorystore AUTH string."
  type        = string
  sensitive   = true
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
