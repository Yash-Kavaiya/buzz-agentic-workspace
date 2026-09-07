variable "project_id" {
  description = "GCP project that hosts this environment."
  type = string
}

variable "name_prefix" {
  description = "Resource name prefix for this environment, e.g. buzz-prod."
  type = string
}

variable "namespace" {
  description = "Kubernetes namespace the Buzz release lives in."
  type        = string
  default     = "buzz"
}

variable "relay_ksa" {
  description = "Kubernetes ServiceAccount the relay Pod runs as (upstream chart: <release>-buzz-relay)."
  type        = string
}

variable "external_secrets_ksa" {
  description = "KSA the External Secrets Operator controller runs as."
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_namespace" {
  description = "Namespace the External Secrets Operator is installed in."
  type    = string
  default = "external-secrets"
}

variable "minio_backup_ksa" {
  description = "KSA the MinIO to GCS mirror CronJob runs as."
  type        = string
  default     = "buzz-minio-backup"
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type    = map(string)
  default = {}
}
