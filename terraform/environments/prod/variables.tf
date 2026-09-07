variable "project_id" {
  description = "GCP project that hosts this environment."
  type = string
}

variable "region" {
  description = "Primary region for every regional resource."
  type    = string
  default = "us-central1"
}

variable "environment" {
  description = "Environment name. Selects the tfvars and the Helm values file."
  type = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

# ── Networking ───────────────────────────────────────────────────────────────
variable "subnet_cidr" {
  description = "Primary node CIDR for the GKE subnet. Must not overlap other environments."
  type    = string
  default = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for Pod IPs. Cannot be changed after the cluster is created."
  type    = string
  default = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for ClusterIP Services."
  type    = string
  default = "10.30.0.0/20"
}

variable "master_cidr" {
  description = "RFC1918 /28 for the private control plane. Must not overlap anything else."
  type    = string
  default = "172.16.0.0/28"
}

# ── Cluster ──────────────────────────────────────────────────────────────────
variable "enable_public_control_plane" {
  description = "Expose the Kubernetes API on a public IP restricted to master_authorized_networks."
  type    = bool
  default = false
}

variable "master_authorized_networks" {
  description = "CIDRs permitted to reach the Kubernetes API."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR or STABLE."
  type    = string
  default = "REGULAR"
}

variable "min_master_version" {
  description = "Minimum control-plane version. 1.29+ is required for the Cloud SQL proxy sidecar."
  type    = string
  default = "1.31"
}

variable "cluster_deletion_protection" {
  description = "Refuse to delete the cluster through Terraform."
  type    = bool
  default = true
}

variable "enable_binary_authorization" {
  description = "Require an attestation before an image may run."
  type    = bool
  default = true
}

variable "attestor_public_key_pem" {
  description = "Public key that verifies mirror attestations."
  type      = string
  default   = ""
  sensitive = false
}

variable "node_pools" {
  description = "Node pools keyed by name: system, buzz and minio."
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

# ── Data services ────────────────────────────────────────────────────────────
variable "postgres_tier" {
  description = "Cloud SQL machine tier."
  type    = string
  default = "db-custom-2-8192"
}

variable "postgres_disk_size_gb" {
  description = "Cloud SQL storage in GiB."
  type    = number
  default = 50
}

variable "postgres_availability_type" {
  description = "REGIONAL for HA with automatic failover; ZONAL for dev."
  type    = string
  default = "ZONAL"
}

variable "postgres_max_connections" {
  description = "Must exceed relay replicas times pool size, plus headroom."
  type    = string
  default = "200"
}

variable "postgres_read_replica" {
  description = "Create a read replica and route relay reads to it."
  type    = bool
  default = false
}

variable "postgres_deletion_protection" {
  description = "Refuse to delete the database instance."
  type    = bool
  default = true
}

variable "redis_tier" {
  description = "STANDARD_HA for a replica and automatic failover; BASIC for dev."
  type    = string
  default = "BASIC"
}

variable "redis_memory_size_gb" {
  description = "Memorystore instance size in GiB."
  type    = number
  default = 1
}

variable "redis_transit_encryption" {
  description = "See modules/memorystore/variables.tf — read the note before changing."
  type        = bool
  default     = true
}

# ── Edge ─────────────────────────────────────────────────────────────────────
variable "domain" {
  description = "Apex domain the workspace lives under."
  type = string
}

variable "relay_hostname" {
  description = "Hostname clients connect to. Becomes relayUrl as wss://<host>."
  type = string
}

variable "admin_hostname" {
  description = "Hostname serving the moderation console, behind IAP."
  type = string
}

variable "dns_zone_name" {
  description = "Existing Cloud DNS zone name. Empty means DNS is managed elsewhere."
  type    = string
  default = ""
}

variable "create_dns_zone" {
  description = "Create the Cloud DNS zone in this project."
  type    = bool
  default = false
}

variable "allowed_source_ranges" {
  description = "CIDRs Cloud Armor permits to reach the relay."
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "blocked_country_codes" {
  description = "ISO 3166-1 alpha-2 codes denied at the edge."
  type    = list(string)
  default = []
}

variable "rate_limit_requests_per_minute" {
  description = "Per-source-IP request ceiling at the edge."
  type    = number
  default = 1200
}

variable "iap_members" {
  description = "Members permitted through IAP to the admin console."
  type    = list(string)
  default = []
}

# ── Kubernetes coordinates ───────────────────────────────────────────────────
variable "namespace" {
  description = "Kubernetes namespace the Buzz release lives in."
  type    = string
  default = "buzz"
}

variable "helm_release_name" {
  description = <<-EOT
    Helm release name. It determines the relay's ServiceAccount name, which the
    Workload Identity binding must match exactly. The upstream chart names it
    <release>-relay when the release name contains "buzz", and
    <release>-buzz-relay otherwise — so keeping "buzz" in the name keeps this
    predictable.
  EOT
  type    = string
  default = "buzz"
}

# ── Backup / DR ──────────────────────────────────────────────────────────────
variable "dr_bucket_location" {
  description = "Location for the object-storage DR bucket. Prefer a different region."
  type    = string
  default = "US"
}

variable "dr_retention_days" {
  description = "How long DR copies and cluster backups are retained."
  type    = number
  default = 90
}

variable "dr_bucket_retention_locked" {
  description = "Apply an irreversible locked retention policy to the DR bucket."
  type    = bool
  default = false
}

# ── Observability ────────────────────────────────────────────────────────────
variable "notification_channels" {
  description = "Monitoring notification channels alerts are delivered to."
  type    = list(string)
  default = []
}

variable "audit_retention_days" {
  description = "How long audit log rows are retained in BigQuery."
  type    = number
  default = 400
}
