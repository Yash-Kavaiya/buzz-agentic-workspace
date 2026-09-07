# Google service accounts and Workload Identity bindings.
#
# One GSA per trust boundary, each bound to exactly one Kubernetes
# ServiceAccount. No GSA is shared between workloads, and none of them can
# read another's secrets.
#
# The node service account is deliberately near-powerless: with Workload
# Identity in force, a pod never inherits node credentials, so the node SA only
# needs enough to log, emit metrics and pull images.

# ── Node VMs ─────────────────────────────────────────────────────────────────
resource "google_service_account" "node" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-node"
  display_name = "Buzz GKE node (${var.name_prefix})"
  description  = "Least-privilege identity for node VMs. Not usable by pods — Workload Identity blocks metadata access."
}

resource "google_project_iam_member" "node" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.node.email}"
}

# ── Relay ────────────────────────────────────────────────────────────────────
# Needs exactly two things from GCP: dial Cloud SQL through the Auth Proxy, and
# authenticate to it as an IAM database user. It does NOT get Secret Manager
# access — secrets arrive as a Kubernetes Secret rendered by External Secrets,
# so a compromised relay cannot enumerate the project's secrets.
resource "google_service_account" "relay" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-relay"
  display_name = "Buzz relay (${var.name_prefix})"
  description  = "Workload Identity target for the relay Pod; Cloud SQL client only."
}

resource "google_project_iam_member" "relay" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.relay.email}"
}

resource "google_service_account_iam_member" "relay_workload_identity" {
  service_account_id = google_service_account.relay.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.relay_ksa}]"
}

# ── External Secrets Operator ────────────────────────────────────────────────
# The only workload with Secret Manager read access. It pulls the payloads and
# materialises them as a Kubernetes Secret; the relay reads that Secret.
resource "google_service_account" "external_secrets" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-eso"
  display_name = "Buzz External Secrets (${var.name_prefix})"
  description  = "Reads platform secrets from Secret Manager and renders them into the cluster."
}

resource "google_service_account_iam_member" "external_secrets_workload_identity" {
  service_account_id = google_service_account.external_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.external_secrets_namespace}/${var.external_secrets_ksa}]"
}

# Note: the per-secret accessor grants live in the secrets module, scoped to
# individual secrets rather than granted project-wide here.

# ── MinIO backup ─────────────────────────────────────────────────────────────
resource "google_service_account" "minio_backup" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-minio-backup"
  display_name = "Buzz MinIO backup (${var.name_prefix})"
  description  = "Mirrors the MinIO bucket to a GCS disaster-recovery bucket."
}

resource "google_service_account_iam_member" "minio_backup_workload_identity" {
  service_account_id = google_service_account.minio_backup.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.minio_backup_ksa}]"
}

# The grant on the DR bucket lives in the backup module: iam -> gke -> backup is
# a straight line, and granting here would close it into a cycle.
