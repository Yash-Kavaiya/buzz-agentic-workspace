# Backups and disaster recovery.
#
# Three independent things are protected, because they fail independently:
#
#   Postgres  — Cloud SQL automated backups + PITR (owned by the cloudsql module)
#   Cluster   — Backup for GKE: namespace manifests and PVC contents
#   Objects   — a GCS bucket the in-cluster MinIO mirrors into nightly
#
# The GCS bucket is a *backup target only*. Buzz cannot run against it: GCS's
# S3-compatible API does not support ETag conditional writes, which the git
# manifest-pointer protocol depends on for writer serialisation. Restoring
# means restoring into MinIO, never repointing the relay at GCS.
# See docs/90-adr/ADR-001-object-storage.md.

resource "google_storage_bucket" "dr" {
  name     = "${var.name_prefix}-object-dr"
  project  = var.project_id
  location = var.dr_bucket_location
  labels   = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # Versioning plus retention is what survives an attacker with the mirror
  # job's credentials: they can write, but they cannot erase history.
  versioning {
    enabled = true
  }

  dynamic "retention_policy" {
    for_each = var.dr_bucket_retention_locked ? [1] : []
    content {
      retention_period = var.dr_retention_days * 24 * 60 * 60
      is_locked        = true
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.dr_retention_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  dynamic "encryption" {
    for_each = var.kms_key_id != "" ? [1] : []
    content {
      default_kms_key_name = var.kms_key_id
    }
  }
}

resource "google_storage_bucket_iam_member" "minio_backup" {
  count = var.minio_backup_service_account != "" ? 1 : 0

  bucket = google_storage_bucket.dr.name
  # objectUser writes and overwrites but cannot delete the bucket or weaken its
  # retention policy. The mirror job must not be able to destroy the backups it
  # is producing — that is the whole defence against a compromised cluster.
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${var.minio_backup_service_account}"
}

# ── Backup for GKE ───────────────────────────────────────────────────────────
resource "google_gke_backup_backup_plan" "this" {
  project  = var.project_id
  name     = "${var.name_prefix}-backup-plan"
  location = var.region
  cluster  = var.cluster_id
  labels   = var.labels

  backup_config {
    include_volume_data = true
    include_secrets     = true

    selected_namespaces {
      namespaces = [var.namespace]
    }

    dynamic "encryption_key" {
      for_each = var.kms_key_id != "" ? [1] : []
      content {
        gcp_kms_encryption_key = var.kms_key_id
      }
    }
  }

  backup_schedule {
    cron_schedule = var.backup_schedule_cron
  }

  retention_policy {
    backup_delete_lock_days = 7
    backup_retain_days      = var.dr_retention_days
  }
}
