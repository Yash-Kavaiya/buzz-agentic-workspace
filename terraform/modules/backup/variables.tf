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

variable "cluster_id" {
  description = "Full GKE cluster id for the Backup for GKE plan."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the Buzz release lives in."
  type        = string
  default     = "buzz"
}

variable "dr_bucket_location" {
  description = "Location for the object-storage DR bucket. Use a different region from the platform for real geographic redundancy."
  type        = string
  default     = "US"
}

variable "dr_retention_days" {
  description = "How long DR copies are retained."
  type        = number
  default     = 90
}

variable "dr_bucket_retention_locked" {
  description = <<-EOT
    Apply a locked retention policy to the DR bucket. Once locked this CANNOT be
    undone or shortened, by anyone, including project owners — that is the point:
    it is what makes the backups ransomware-resistant. Leave false until you are
    certain of the retention period.
  EOT
  type        = bool
  default     = false
}

variable "backup_schedule_cron" {
  description = "Cron for the GKE backup plan. Default: nightly at 03:30 UTC."
  type        = string
  default     = "30 3 * * *"
}

variable "kms_key_id" {
  description = "Customer-managed encryption key. Empty uses Google-managed keys."
  type        = string
  default     = ""
}

variable "minio_backup_service_account" {
  description = "GSA the MinIO mirror CronJob impersonates. Granted write-but-not-delete on the DR bucket."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
