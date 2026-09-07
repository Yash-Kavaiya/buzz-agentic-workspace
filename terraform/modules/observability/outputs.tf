output "audit_dataset_id" {
  value = var.create_audit_sink ? google_bigquery_dataset.audit[0].dataset_id : ""
}

output "uptime_check_id" {
  value = google_monitoring_uptime_check_config.relay.uptime_check_id
}

output "alert_policy_names" {
  value = [
    google_monitoring_alert_policy.relay_down.name,
    google_monitoring_alert_policy.storage_sweep_failing.name,
    google_monitoring_alert_policy.db_pool_timeouts.name,
    google_monitoring_alert_policy.certificate_expiry.name,
  ]
}
