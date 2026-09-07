# ── Staging: production's shape at a smaller size ────────────────────────────
# Same HA topology, same security controls, same code paths — so that a change
# that passes here is a change that will behave in production.

project_id  = "REPLACE-WITH-PROJECT-ID"
region      = "us-central1"
environment = "staging"

domain         = "example.com"
relay_hostname = "buzz-staging.example.com"
admin_hostname = "buzz-staging-admin.example.com"
dns_zone_name  = ""

# Non-overlapping with dev and prod so the environments can be VPC-peered for
# a migration without renumbering.
subnet_cidr   = "10.11.0.0/20"
pods_cidr     = "10.21.0.0/16"
services_cidr = "10.31.0.0/20"
master_cidr   = "172.16.0.16/28"

enable_public_control_plane = false
master_authorized_networks = [
  # { cidr_block = "203.0.113.0/24", display_name = "office egress" },
]

enable_binary_authorization = true
# attestor_public_key_pem = file("../../keys/attestor.pub.pem")

node_pools = {
  system = {
    machine_type = "e2-standard-2"
    min_count    = 1
    max_count    = 3
  }
  buzz = {
    machine_type = "n2-standard-4"
    min_count    = 1
    max_count    = 5
  }
  minio = {
    machine_type = "n2-standard-4"
    disk_type    = "pd-ssd"
    disk_size_gb = 200
    min_count    = 2
    max_count    = 2
    labels       = { "buzz.io/workload" = "minio" }
    taints = [{
      key    = "buzz.io/minio"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]
  }
}

postgres_tier              = "db-custom-2-8192"
postgres_disk_size_gb      = 100
postgres_availability_type = "REGIONAL"
postgres_max_connections   = "300"
postgres_read_replica      = false

redis_tier               = "STANDARD_HA"
redis_memory_size_gb     = 2
redis_transit_encryption = true

allowed_source_ranges          = ["0.0.0.0/0"]
rate_limit_requests_per_minute = 1200

dr_bucket_location        = "US"
dr_retention_days         = 30
dr_bucket_retention_locked = false

audit_retention_days = 90
