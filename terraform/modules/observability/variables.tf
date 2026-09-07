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

variable "cluster_name" {
  description = "Name of the GKE cluster this applies to."
  type        = string
}

variable "relay_hostname" {
  description = "Public hostname clients connect to."
  type        = string
}

variable "notification_channels" {
  description = "Existing Monitoring notification channel ids. Alerts without a channel are alerts nobody sees."
  type        = list(string)
  default     = []
}

variable "audit_dataset_id" {
  description = "BigQuery dataset for the audit log sink."
  type        = string
  default     = "buzz_audit"
}

variable "audit_retention_days" {
  description = "Table expiry for audit rows. Set to your compliance retention, not a convenient number."
  type        = number
  default     = 400
}

variable "create_audit_sink" {
  description = "Export audit logs to BigQuery."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
