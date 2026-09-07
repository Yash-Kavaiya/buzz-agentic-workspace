variable "project_id" {
  description = "GCP project that hosts this environment."
  type = string
}

variable "region" {
  description = "Primary region. All regional resources land here."
  type = string
}

variable "name_prefix" {
  description = "Resource name prefix for this environment, e.g. buzz-prod."
  type = string
}

variable "repository_id" {
  description = "Artifact Registry repository name."
  type    = string
  default = "buzz"
}

variable "kms_key_id" {
  description = "CMEK for image layers. Empty uses Google-managed keys."
  type        = string
  default     = ""
}

variable "readers" {
  description = "Members granted pull access (node SA, and anything else that must run these images)."
  type        = list(string)
  default     = []
}

variable "writers" {
  description = "Members granted push access. Only the CI deployer and an operator break-glass group belong here."
  type        = list(string)
  default     = []
}

variable "enable_binary_authorization" {
  description = "Require an attestation before an image may run in the cluster."
  type    = bool
  default = true
}

variable "attestor_note_id" {
  description = "Container Analysis note backing the Binary Authorization attestor."
  type    = string
  default = "buzz-mirror-attestor-note"
}

variable "attestor_public_key_pem" {
  description = <<-EOT
    PGP or PKIX public key that verifies mirror attestations. Empty creates the
    attestor with no key, which means nothing can satisfy the policy — safe by
    default, but you must supply a key (or set enable_binary_authorization to
    false) before the first deploy.
  EOT
  type    = string
  default = ""
}

variable "binauthz_allowlist_patterns" {
  description = <<-EOT
    Image name patterns exempt from attestation. Kept for the images GKE itself
    injects (system add-ons, GMP collectors) which are not ours to attest.
  EOT
  type = list(string)
  default = [
    "gcr.io/gke-release/*",
    "gke.gcr.io/*",
    "gcr.io/gkeconnect/*",
    "gcr.io/gkebackup/*",
    "gcr.io/cloud-sql-connectors/*",
    "gcr.io/google-containers/*",
    "gcr.io/projectcalico-org/*",
    "gcr.io/distroless/*",
  ]
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type    = map(string)
  default = {}
}
