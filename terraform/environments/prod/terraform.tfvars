# ── Production ───────────────────────────────────────────────────────────────
# Everything protected, everything regional, everything private.
#
# Before the first apply, decide two things deliberately:
#   allowed_source_ranges       — leaving it open is a choice, not a default
#   dr_bucket_retention_locked  — locking is irreversible; see modules/backup

project_id  = "REPLACE-WITH-PROJECT-ID"
region      = "us-central1"
environment = "prod"

domain         = "example.com"
relay_hostname = "buzz.example.com"
admin_hostname = "buzz-admin.example.com"
dns_zone_name  = ""

subnet_cidr   = "10.12.0.0/20"
pods_cidr     = "10.22.0.0/16"
services_cidr = "10.32.0.0/20"
master_cidr   = "172.16.0.32/28"

# The API server has no public endpoint. Reach it from a bastion in the VPC,
# through Cloud VPN, or via the GKE Connect gateway.
enable_public_control_plane = false
master_authorized_networks = [
  # { cidr_block = "10.12.0.0/20", display_name = "in-VPC bastion" },
]

cluster_deletion_protection  = true
postgres_deletion_protection = true

enable_binary_authorization = true
# attestor_public_key_pem = file("../../keys/attestor.pub.pem")

node_pools = {
  system = {
    machine_type = "n2-standard-2"
    min_count    = 1
    max_count    = 3
  }
  buzz = {
    machine_type = "n2-standard-8"
    disk_size_gb = 200
    min_count    = 2
    max_count    = 10
  }
  # Fixed at 4 nodes: MinIO's erasure set is sized at deployment and autoscaling
  # the pool would either strand drives or leave the set degraded. Grow it by
  # deliberately raising both counts together and rebalancing.
  minio = {
    machine_type = "n2-standard-8"
    disk_type    = "pd-ssd"
    disk_size_gb = 1000
    min_count    = 4
    max_count    = 4
    labels       = { "buzz.io/workload" = "minio" }
    taints = [{
      key    = "buzz.io/minio"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]
  }
}

postgres_tier              = "db-custom-8-32768"
postgres_disk_size_gb      = 500
postgres_availability_type = "REGIONAL"
postgres_max_connections   = "600"
postgres_read_replica      = true

redis_tier               = "STANDARD_HA"
redis_memory_size_gb     = 5
redis_transit_encryption = true

# Narrow this to corporate egress if every client is on the network or VPN.
allowed_source_ranges          = ["0.0.0.0/0"]
blocked_country_codes          = []
rate_limit_requests_per_minute = 1200

# Operators who may reach the moderation console through IAP.
iap_members = [
  # "group:buzz-operators@example.com",
]

dr_bucket_location        = "NAM4"
dr_retention_days         = 90
dr_bucket_retention_locked = false

audit_retention_days = 400

notification_channels = [
  # "projects/PROJECT/notificationChannels/1234567890",
]
