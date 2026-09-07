# Artifact Registry + Binary Authorization.
#
# Buzz images are published to ghcr.io. We do not run them from there:
# `buzzctl images mirror` copies the tag into this repository, resolves the
# immutable digest, attests it, and writes the digest into the environment
# values. The relay is then deployed by digest, so what runs is exactly what
# was reviewed — a retagged upstream image cannot silently replace it.

resource "google_artifact_registry_repository" "buzz" {
  project       = var.project_id
  location      = var.region
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "Mirrored, attested Buzz relay images for ${var.name_prefix}."
  labels        = var.labels

  kms_key_name = var.kms_key_id != "" ? var.kms_key_id : null

  docker_config {
    immutable_tags = true # a tag, once pushed, cannot be moved to different bytes
  }

  cleanup_policies {
    id     = "keep-recent-versions"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }

  cleanup_policies {
    id     = "delete-untagged-after-30d"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s"
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = toset(var.readers)

  project    = var.project_id
  location   = google_artifact_registry_repository.buzz.location
  repository = google_artifact_registry_repository.buzz.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each = toset(var.writers)

  project    = var.project_id
  location   = google_artifact_registry_repository.buzz.location
  repository = google_artifact_registry_repository.buzz.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}

# ── Binary Authorization ─────────────────────────────────────────────────────
resource "google_container_analysis_note" "attestor" {
  count = var.enable_binary_authorization ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-${var.attestor_note_id}"

  attestation_authority {
    hint {
      human_readable_name = "Buzz mirror attestor (${var.name_prefix})"
    }
  }
}

resource "google_binary_authorization_attestor" "mirror" {
  count = var.enable_binary_authorization ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-mirror-attestor"

  attestation_authority_note {
    note_reference = google_container_analysis_note.attestor[0].name

    dynamic "public_keys" {
      for_each = var.attestor_public_key_pem != "" ? [1] : []
      content {
        id                                  = "buzz-mirror-key"
        ascii_armored_pgp_public_key        = var.attestor_public_key_pem
      }
    }
  }
}

resource "google_binary_authorization_policy" "this" {
  count = var.enable_binary_authorization ? 1 : 0

  project                       = var.project_id
  global_policy_evaluation_mode = "ENABLE"

  dynamic "admission_whitelist_patterns" {
    for_each = var.binauthz_allowlist_patterns
    content {
      name_pattern = admission_whitelist_patterns.value
    }
  }

  # Everything not explicitly allowlisted must carry an attestation from our
  # attestor. Deployments that fail this are blocked at admission, not warned.
  default_admission_rule {
    evaluation_mode  = "REQUIRE_ATTESTATION"
    enforcement_mode = "ENFORCED_BLOCK_AND_AUDIT_LOG"
    require_attestations_by = [
      google_binary_authorization_attestor.mirror[0].name,
    ]
  }
}
