# Outputs are the contract between Terraform and everything downstream.
# `buzzctl` reads `platform` as JSON and renders the Helm values from it, so a
# field added here is available to the deploy without editing the CLI.

output "platform" {
  description = "Everything buzzctl and the Helm values need. No secret values — only references to them."
  value = {
    environment = var.environment
    project_id  = var.project_id
    region      = var.region
    name_prefix = local.name_prefix
    namespace   = var.namespace
    release     = var.helm_release_name

    cluster = {
      name             = module.gke.cluster_name
      location         = module.gke.location
      get_credentials  = module.gke.get_credentials_command
      workload_pool    = module.gke.workload_identity_pool
      node_pools       = module.gke.node_pool_names
    }

    identity = {
      relay_ksa                        = local.relay_ksa
      relay_service_account            = module.iam.relay_service_account
      external_secrets_service_account = module.iam.external_secrets_service_account
      minio_backup_service_account     = module.iam.minio_backup_service_account
      relay_iam_db_user                = module.iam.relay_iam_db_user
    }

    database = {
      connection_name         = module.cloudsql.connection_name
      replica_connection_name = module.cloudsql.replica_connection_name
      database                = module.cloudsql.database_name
      user                    = module.cloudsql.app_user
      read_replica_enabled    = var.postgres_read_replica
    }

    redis = {
      host                       = module.memorystore.host
      port                       = module.memorystore.port
      transit_encryption_enabled = module.memorystore.transit_encryption_enabled
    }

    edge = {
      relay_url            = module.edge.relay_url
      relay_hostname       = module.edge.relay_hostname
      admin_hostname       = module.edge.admin_hostname
      gateway_ip_name      = module.edge.gateway_ip_name
      gateway_ip_address   = module.edge.gateway_ip_address
      certificate_map_name = module.edge.certificate_map_name
      security_policy_name = module.edge.security_policy_name
    }

    registry = {
      repository_url = module.artifact_registry.repository_url
      attestor_name  = module.artifact_registry.attestor_name
    }

    secrets = {
      prefix                  = module.secrets.prefix
      ids                     = module.secrets.secret_ids
      awaiting_buzzctl_init   = module.secrets.externally_populated_secret_ids
    }

    backup = {
      dr_bucket        = module.backup.dr_bucket_name
      dr_bucket_url    = module.backup.dr_bucket_url
      backup_plan_name = module.backup.backup_plan_name
    }
  }
}

# ── Convenience outputs, for humans at a terminal ────────────────────────────
output "relay_url" {
  value = module.edge.relay_url
}

output "get_credentials_command" {
  value = module.gke.get_credentials_command
}

output "dns_authorization_records" {
  description = "Create these in your zone if DNS is managed outside this project; certificates will not issue without them."
  value       = module.edge.dns_authorization_records
}

output "next_steps" {
  value = <<-EOT
    Infrastructure is up. Nothing is serving yet — the relay needs secrets and an image.

      buzzctl secrets init ${var.environment}    # generate + store the relay identity, HMAC and MinIO credentials
      buzzctl images mirror ${var.environment}   # copy ghcr.io/block/buzz into Artifact Registry and pin the digest
      buzzctl preflight ${var.environment}       # prove object-storage conditional writes before deploying
      buzzctl deploy ${var.environment}
      buzzctl verify ${var.environment}

    Secrets still awaiting a version:
      ${join("\n      ", module.secrets.externally_populated_secret_ids)}
  EOT
}
