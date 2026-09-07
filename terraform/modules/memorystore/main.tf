# Memorystore for Redis — the relay's pubsub / presence / typing backplane.
#
# Required as soon as replicaCount > 1: buzz-pubsub fans events between relay
# replicas through it, so a single-replica deployment is the only one that can
# run without it.
#
# It is a cache and a bus, not a store of record. Losing it drops presence and
# in-flight fanout; the event log in Postgres and the media/git state in object
# storage are unaffected.

resource "google_redis_instance" "this" {
  project        = var.project_id
  name           = "${var.name_prefix}-redis"
  region         = var.region
  tier           = var.tier
  memory_size_gb = var.memory_size_gb
  redis_version  = var.redis_version

  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  # AUTH is non-negotiable even on a private network: it is what stops any
  # pod that can route to the instance from reading every other tenant's fanout.
  auth_enabled = true

  transit_encryption_mode = var.transit_encryption_enabled ? "SERVER_AUTHENTICATION" : "DISABLED"

  redis_configs = {
    # Presence and typing keys are disposable; evict rather than start
    # rejecting writes when memory fills.
    maxmemory-policy       = "allkeys-lru"
    notify-keyspace-events = ""
  }

  maintenance_policy {
    weekly_maintenance_window {
      day = var.maintenance_day
      start_time {
        hours   = 4
        minutes = 0
      }
    }
  }

  labels = var.labels

  depends_on = [var.private_service_connection]

  lifecycle {
    prevent_destroy = true
  }
}
