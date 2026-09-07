variable "project_id" {
  description = "GCP project that hosts this environment."
  type = string
}

variable "region" {
  description = "KMS location. Must match the region of the resources being encrypted."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix for this environment, e.g. buzz-prod."
  type = string
}

variable "rotation_period" {
  description = "Automatic key rotation period. 90 days is a common control-framework floor."
  type        = string
  default     = "7776000s"
}

variable "prevent_destroy" {
  description = <<-EOT
    Guard against destroying key rings. Destroying a key makes every resource
    encrypted with it permanently unreadable, so this defaults to on.
  EOT
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type    = map(string)
  default = {}
}
