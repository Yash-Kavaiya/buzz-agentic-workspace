variable "project_id" {
  description = "GCP project that hosts this environment."
  type        = string
}

variable "region" {
  description = "Primary region. All regional resources land here."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix, e.g. buzz-prod."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary node CIDR for the GKE subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = <<-EOT
    Secondary range for Pod IPs. Size this for the cluster's lifetime — a
    VPC-native cluster cannot change its pod range after creation. /16 supports
    roughly 256 nodes at the default 110 pods/node.
  EOT
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for ClusterIP Services."
  type        = string
  default     = "10.30.0.0/20"
}

variable "master_cidr" {
  description = "RFC1918 /28 for the GKE control plane's peered network. Must not overlap anything else."
  type        = string
  default     = "172.16.0.0/28"
}

variable "psa_prefix_length" {
  description = "Prefix length for the Private Service Access block that Cloud SQL and Memorystore allocate from."
  type        = number
  default     = 16
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
