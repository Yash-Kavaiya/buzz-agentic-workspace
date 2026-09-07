# Customer-managed encryption keys.
#
# Four separate keys rather than one, so that a compromise or rotation of one
# blast radius does not force re-encrypting the others, and so that IAM can be
# granted per-purpose to the specific Google service agent that needs it.
#
# WARNING: key destruction is irreversible and takes every resource encrypted
# with that key with it. `google_kms_key_ring` cannot be deleted at all once
# created; Terraform will only drop it from state.

locals {
  keys = {
    gke      = "GKE etcd application-layer secrets encryption"
    cloudsql = "Cloud SQL data and backup encryption"
    secrets  = "Secret Manager payload encryption"
    artifact = "Artifact Registry image layer encryption"
    storage  = "Cloud Storage encryption for the object-storage DR bucket"
  }
}

resource "google_kms_key_ring" "this" {
  project  = var.project_id
  name     = "${var.name_prefix}-keys"
  location = var.region
}

resource "google_kms_crypto_key" "this" {
  for_each = local.keys

  name     = "${var.name_prefix}-${each.key}"
  key_ring = google_kms_key_ring.this.id
  purpose  = "ENCRYPT_DECRYPT"
  labels   = var.labels

  rotation_period = var.rotation_period

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ── Service-agent grants ─────────────────────────────────────────────────────
# Each Google-managed service encrypts with its own service agent identity.
# These grants are what make `kms_key_name` on the consuming resource work; a
# missing one surfaces as an opaque "permission denied on key" at create time.

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  project_number = data.google_project.this.number

  service_agents = {
    gke      = "serviceAccount:service-${local.project_number}@container-engine-robot.iam.gserviceaccount.com"
    cloudsql = "serviceAccount:service-${local.project_number}@gcp-sa-cloud-sql.iam.gserviceaccount.com"
    secrets  = "serviceAccount:service-${local.project_number}@gcp-sa-secretmanager.iam.gserviceaccount.com"
    artifact = "serviceAccount:service-${local.project_number}@gcp-sa-artifactregistry.iam.gserviceaccount.com"
    storage  = "serviceAccount:service-${local.project_number}@gs-project-accounts.iam.gserviceaccount.com"
  }
}

resource "google_kms_crypto_key_iam_member" "service_agents" {
  for_each = local.service_agents

  crypto_key_id = google_kms_crypto_key.this[each.key].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = each.value
}
