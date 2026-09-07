# ── Dev: cheapest shape that still exercises every code path ─────────────────
# Single-zone data services, small nodes, deletion protection off so the whole
# environment can be torn down and rebuilt while iterating.

project_id  = "REPLACE-WITH-PROJECT-ID"
region      = "us-central1"
environment = "dev"

domain          = "example.com"
relay_hostname  = "buzz-dev.example.com"
admin_hostname  = "buzz-dev-admin.example.com"
dns_zone_name   = ""
create_dns_zone = false

# Reachable from a laptop. Never do this above dev.
enable_public_control_plane = true
master_authorized_networks = [
  # { cidr_block = "203.0.113.0/24", display_name = "office egress" },
]

cluster_deletion_protection  = false
postgres_deletion_protection = false

# Binary Authorization needs an attestor key. Off in dev so the first deploy is
# not blocked on key ceremony; on everywhere else.
enable_binary_authorization = false

node_pools = {
  system = {
    machine_type = "e2-standard-2"
    min_count    = 1
    max_count    = 2
  }
  buzz = {
    machine_type = "e2-standard-4"
    min_count    = 1
    max_count    = 3
  }
  minio = {
    machine_type = "e2-standard-4"
    disk_type    = "pd-balanced"
    disk_size_gb = 100
    min_count    = 1
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
postgres_disk_size_gb      = 50
postgres_availability_type = "ZONAL"
postgres_max_connections   = "200"
postgres_read_replica      = false

redis_tier               = "BASIC"
redis_memory_size_gb     = 1
redis_transit_encryption = true

allowed_source_ranges          = ["0.0.0.0/0"]
rate_limit_requests_per_minute = 3000

dr_bucket_location         = "US"
dr_retention_days          = 14
dr_bucket_retention_locked = false

audit_retention_days = 30
