# Observability: audit log export, alerting, uptime checking.
#
# Metric scraping itself is Google Managed Prometheus, enabled on the cluster
# and pointed at the relay by the PodMonitoring the Helm chart ships. The alert
# policies below query the relay's own Prometheus families through GMP, so they
# are meaningful only once that PodMonitoring is applied.

# ── Audit export ─────────────────────────────────────────────────────────────
resource "google_bigquery_dataset" "audit" {
  count = var.create_audit_sink ? 1 : 0

  project                     = var.project_id
  dataset_id                  = var.audit_dataset_id
  friendly_name               = "Buzz audit logs"
  description                 = "Admin activity, data access and GKE audit events for the Buzz platform."
  location                    = var.region
  default_table_expiration_ms = var.audit_retention_days * 24 * 60 * 60 * 1000
  labels                      = var.labels

  # Deleting an audit dataset should be a deliberate, separate act.
  delete_contents_on_destroy = false
}

resource "google_logging_project_sink" "audit" {
  count = var.create_audit_sink ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-audit-sink"
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.audit[0].dataset_id}"

  # Admin writes, data access, and everything the cluster's API server saw.
  filter = <<-EOT
    logName:"cloudaudit.googleapis.com" OR
    (resource.type="k8s_cluster" AND resource.labels.cluster_name="${var.cluster_name}")
  EOT

  unique_writer_identity = true

  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_bigquery_dataset_iam_member" "sink_writer" {
  count = var.create_audit_sink ? 1 : 0

  project    = var.project_id
  dataset_id = google_bigquery_dataset.audit[0].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.audit[0].writer_identity
}

# ── Uptime ───────────────────────────────────────────────────────────────────
# Checks the relay's NIP-11 document, which requires the app listener, the
# database and the config to all be healthy — a better signal than a bare TCP
# connect.
resource "google_monitoring_uptime_check_config" "relay" {
  project      = var.project_id
  display_name = "${var.name_prefix} relay NIP-11"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/"
    port         = 443
    use_ssl      = true
    validate_ssl = true

    headers = {
      # NIP-11: the relay returns its information document for this Accept type.
      "Accept" = "application/nostr+json"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.relay_hostname
    }
  }

  content_matchers {
    content = "supported_nips"
    matcher = "CONTAINS_STRING"
  }
}

resource "google_monitoring_alert_policy" "relay_down" {
  project      = var.project_id
  display_name = "${var.name_prefix} relay unreachable"
  combiner     = "OR"
  severity     = "CRITICAL"

  documentation {
    content   = <<-EOT
      The relay is not serving its NIP-11 document over HTTPS.

      Triage order:
        1. `buzzctl status <env>` — are relay pods Ready?
        2. If pods are not Ready, check the readiness probe. The relay's own
           git object-store conformance probe runs at startup and is fatal:
           a MinIO outage or a credential change presents as a relay that
           never becomes Ready. `buzzctl preflight <env>` reproduces it.
        3. If pods are Ready, the fault is at the edge: Gateway programming,
           certificate state, or a Cloud Armor rule.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Uptime check failing"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${google_monitoring_uptime_check_config.relay.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "180s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_FRACTION_TRUE"
        cross_series_reducer = "REDUCE_MEAN"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_alert_policy" "storage_sweep_failing" {
  project      = var.project_id
  display_name = "${var.name_prefix} object-storage sweep failing"
  combiner     = "OR"
  severity     = "WARNING"

  documentation {
    content   = <<-EOT
      `buzz_storage_sweep_ok` is 0: the relay's hourly bucket sweep is failing.

      Most often the MinIO credentials lack bucket-level `s3:ListBucket`, which
      is a distinct grant from the object-level permissions media needs. Media
      upload and download are unaffected while this is firing, so it is a
      warning rather than a page — but usage metrics and the deletion control
      plane both depend on it.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "buzz_storage_sweep_ok == 0"
    condition_threshold {
      filter          = "resource.type = \"prometheus_target\" AND metric.type = \"prometheus.googleapis.com/buzz_storage_sweep_ok/gauge\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "1800s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_alert_policy" "db_pool_timeouts" {
  project      = var.project_id
  display_name = "${var.name_prefix} database pool acquisition timeouts"
  combiner     = "OR"
  severity     = "ERROR"

  documentation {
    content   = <<-EOT
      `buzz_db_pool_acquire_attempts_total{outcome="timeout"}` is climbing:
      relay workers are waiting for a Postgres connection and giving up.

      Either the pool is too small for the replica count, or Cloud SQL is at
      its `max_connections` ceiling. Check the cloudsql module's max_connections
      against (relay replicas x writer pool size) before enlarging the instance.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Acquire timeouts over 5 minutes"
    condition_threshold {
      filter          = "resource.type = \"prometheus_target\" AND metric.type = \"prometheus.googleapis.com/buzz_db_pool_acquire_attempts_total/counter\" AND metric.labels.outcome = \"timeout\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_alert_policy" "certificate_expiry" {
  project      = var.project_id
  display_name = "${var.name_prefix} TLS certificate expiring"
  combiner     = "OR"
  severity     = "WARNING"

  documentation {
    content   = "A managed certificate is within 20 days of expiry. Managed renewal needs the DNS authorization record to still be present in the zone — check it has not been pruned."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Uptime SSL expiry under 20 days"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires\""
      comparison      = "COMPARISON_LT"
      threshold_value = 20
      duration        = "3600s"

      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_MIN"
      }
    }
  }

  notification_channels = var.notification_channels
}
