variable "project_id" {
  description = "GCP project that hosts the Buzz platform."
  type        = string
}

variable "region" {
  description = "Primary region. Everything regional (GKE, Cloud SQL, Memorystore) lands here."
  type        = string
  default     = "us-central1"
}

variable "state_bucket_name" {
  description = "Globally unique GCS bucket for Terraform remote state. Defaults to <project>-buzz-tfstate."
  type        = string
  default     = ""
}

variable "state_bucket_location" {
  description = "Location for the Terraform state bucket. Prefer a multi-region or dual-region for durability."
  type        = string
  default     = "US"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI deployer identity via Workload Identity Federation."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be in owner/repo form."
  }
}

variable "github_allowed_refs" {
  description = <<-EOT
    Git refs permitted to assume the CI deployer identity. Kept narrow on purpose:
    a wildcard here means any branch in the repo can reach production.
  EOT
  type        = list(string)
  default     = ["refs/heads/main"]
}

variable "enable_apis" {
  description = "Enable the required Google APIs. Set false when a landing-zone pipeline already owns API enablement."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to every bootstrap-created resource."
  type        = map(string)
  default = {
    platform  = "buzz"
    component = "bootstrap"
    managed-by = "terraform"
  }
}
