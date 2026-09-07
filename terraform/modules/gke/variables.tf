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

variable "subnet_id" {
  description = "Subnet id the cluster's nodes live in."
  type = string
}

variable "pods_range_name" {
  description = "Secondary range name for Pod IPs."
  type = string
}

variable "services_range_name" {
  description = "Secondary range name for ClusterIP Services."
  type = string
}

variable "master_cidr" {
  description = "RFC1918 /28 for the private control plane."
  type        = string
}

variable "master_authorized_networks" {
  description = <<-EOT
    CIDRs allowed to reach the Kubernetes API. The control plane has no public
    endpoint unless enable_public_endpoint is true, in which case this list is
    the only thing standing between the API server and the internet — keep it
    to the CI egress range and the corporate VPN.
  EOT
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "enable_public_endpoint" {
  description = <<-EOT
    Expose the control plane on a public IP restricted to master_authorized_networks.
    Production should leave this false and reach the API through a bastion,
    Connect gateway, or Cloud VPN. Set it true only for a dev cluster you drive
    from a laptop.
  EOT
  type    = bool
  default = false
}

variable "release_channel" {
  description = "GKE release channel. REGULAR balances feature currency against churn."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "min_master_version" {
  description = <<-EOT
    Minimum control-plane version. Must be >= 1.29 — the Cloud SQL Auth Proxy
    runs as a native sidecar (an init container with restartPolicy: Always),
    which is only honoured from 1.29 onwards.
  EOT
  type    = string
  default = "1.31"
}

variable "database_encryption_key" {
  description = "KMS key for application-layer Secret encryption in etcd."
  type        = string
}

variable "enable_binary_authorization" {
  description = "Require an attestation before an image may run in the cluster."
  type    = bool
  default = true
}

variable "enable_backup_agent" {
  description = "Install the Backup for GKE agent. Required by the backup plan in the observability/backup wiring."
  type        = bool
  default     = true
}

variable "node_tag" {
  description = "Network tag applied to every node so the VPC firewall rules match."
  type        = string
}

variable "node_service_account" {
  description = "Least-privilege service account for node VMs. Never the default compute SA."
  type        = string
}

variable "maintenance_start_time" {
  description = "RFC3339 start of the weekly maintenance window."
  type        = string
  default     = "2026-01-04T03:00:00Z"
}

variable "maintenance_recurrence" {
  description = "RRULE for the maintenance window."
  type    = string
  default = "FREQ=WEEKLY;BYDAY=SA,SU"
}

variable "node_pools" {
  description = <<-EOT
    Node pools keyed by name. Three are expected:
      system — cluster add-ons (CoreDNS, ESO, GMP collectors)
      buzz   — the relay; scales with connection count
      minio  — object storage; tainted so only MinIO schedules there, and sized
               for a stable erasure set (do not autoscale below min_count)
  EOT
  type = map(object({
    machine_type    = string
    disk_type       = optional(string, "pd-balanced")
    disk_size_gb    = optional(number, 100)
    min_count       = number
    max_count       = number
    initial_count   = optional(number)
    spot            = optional(bool, false)
    local_ssd_count = optional(number, 0)
    labels          = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type    = map(string)
  default = {}
}

variable "deletion_protection" {
  description = "Refuse to delete the cluster through Terraform. Leave on for anything above dev."
  type        = bool
  default     = true
}
