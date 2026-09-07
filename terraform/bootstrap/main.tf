# Bootstrap — run once per project, with an operator identity, before any
# environment stack exists. It creates the things Terraform itself needs:
# enabled APIs, a versioned remote-state bucket, and a keyless CI identity.
#
#   terraform -chdir=terraform/bootstrap init
#   terraform -chdir=terraform/bootstrap apply
#
# This stack keeps LOCAL state on purpose (it creates the bucket that every
# other stack stores state in). Commit nothing from here; the outputs are
# re-read by `buzzctl` and by terraform/environments/*/backend.tf.

locals {
  state_bucket = coalesce(var.state_bucket_name, "${var.project_id}-buzz-tfstate")

  required_apis = [
    "artifactregistry.googleapis.com",
    "binaryauthorization.googleapis.com",
    "certificatemanager.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "containeranalysis.googleapis.com",
    "dns.googleapis.com",
    "gkebackup.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "networkmanagement.googleapis.com",
    "redis.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ]
}

resource "google_project_service" "required" {
  for_each = var.enable_apis ? toset(local.required_apis) : toset([])

  project = var.project_id
  service = each.value

  # Never let a `terraform destroy` of the platform switch off APIs that other
  # workloads in the project may depend on.
  disable_on_destroy         = false
  disable_dependent_services = false
}

# ── Terraform remote state ───────────────────────────────────────────────────
# Versioning is the recovery path for a corrupted or truncated state write, and
# uniform bucket-level access keeps ACLs out of the picture entirely.
# No CMEK here, unavoidably: this bucket is created by
# the bootstrap stack, which runs before any environment exists and therefore
# before the KMS key ring does. Google-managed encryption applies. The buckets
# that hold actual platform data — the object-storage DR bucket — do use CMEK.
# trivy:ignore:AVD-GCP-0066
resource "google_storage_bucket" "tfstate" {
  name     = local.state_bucket
  project  = var.project_id
  location = var.state_bucket_location
  labels   = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 30
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 90
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.required]
}

# ── Keyless CI identity ──────────────────────────────────────────────────────
# GitHub Actions authenticates by exchanging its OIDC token for short-lived
# GCP credentials. No service-account JSON key is ever created, so there is no
# long-lived credential to leak or rotate.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "buzz-github-pool"
  display_name              = "Buzz GitHub Actions"
  description               = "Keyless CI identity for the buzz-agentic-workspace repository."

  depends_on = [google_project_service.required]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.actor"      = "assertion.actor"
  }

  # A principalSet can key on exactly one attribute, so repository *and* ref
  # narrowing both live here. Without the ref clause any branch in the repo
  # could open a PR that reaches production credentials.
  attribute_condition = join(" && ", [
    "assertion.repository == \"${var.github_repository}\"",
    format("assertion.ref in [%s]", join(", ", formatlist("%q", var.github_allowed_refs))),
  ])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ci_deployer" {
  project      = var.project_id
  account_id   = "buzz-ci-deployer"
  display_name = "Buzz CI deployer"
  description  = "Assumed by GitHub Actions via Workload Identity Federation to plan and apply the platform."
}

resource "google_service_account_iam_member" "ci_workload_identity" {
  service_account_id = google_service_account.ci_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member = format(
    "principalSet://iam.googleapis.com/%s/attribute.repository/%s",
    google_iam_workload_identity_pool.github.name,
    var.github_repository,
  )
}

# The CI identity can read state and plan; `apply` in production is gated by a
# GitHub environment approval, not by broader IAM.
resource "google_storage_bucket_iam_member" "ci_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.ci_deployer.email}"
}

resource "google_project_iam_member" "ci_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.ci_deployer.email}"
}
