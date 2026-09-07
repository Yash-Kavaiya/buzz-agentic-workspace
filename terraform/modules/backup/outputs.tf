output "dr_bucket_name" {
  value = google_storage_bucket.dr.name
}

output "dr_bucket_url" {
  value = "gs://${google_storage_bucket.dr.name}"
}

output "backup_plan_name" {
  value = google_gke_backup_backup_plan.this.name
}
