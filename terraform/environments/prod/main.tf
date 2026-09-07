# One Buzz environment, end to end.
#
# Apply order is expressed entirely through data flow, not depends_on:
#   kms -> iam -> network -> gke -> {cloudsql, memorystore} -> secrets
#                                -> backup -> edge -> observability
#
# The relay's Kubernetes ServiceAccount name is computed here rather than
# hardcoded, because the Workload Identity binding is only valid if it matches
# what the upstream chart actually renders.

locals {
  name_prefix = "buzz-${var.environment}"

  labels = {
    platform    = "buzz"
    environment = var.environment
    managed-by  = "terraform"
  }

  # Mirrors deploy/charts/buzz/templates/_helpers.tpl: the chart prefixes with
  # the release name alone when that name already contains "buzz", and with
  # "<release>-buzz" otherwise.
  relay_ksa = strcontains(var.helm_release_name, "buzz") ? "${var.helm_release_name}-relay" : "${var.helm_release_name}-buzz-relay"
}

module "kms" {
  source = "../../modules/kms"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix
  labels      = local.labels
}

module "iam" {
  source = "../../modules/iam"

  project_id  = var.project_id
  name_prefix = local.name_prefix
  namespace   = var.namespace
  relay_ksa   = local.relay_ksa
  labels      = local.labels
}

module "network" {
  source = "../../modules/network"

  project_id    = var.project_id
  region        = var.region
  name_prefix   = local.name_prefix
  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr
  master_cidr   = var.master_cidr
  labels        = local.labels
}

module "gke" {
  source = "../../modules/gke"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  network_id          = module.network.network_id
  subnet_id           = module.network.subnet_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  master_cidr         = module.network.master_cidr
  node_tag            = module.network.node_tag

  node_service_account = module.iam.node_service_account

  enable_public_endpoint      = var.enable_public_control_plane
  master_authorized_networks  = var.master_authorized_networks
  release_channel             = var.release_channel
  min_master_version          = var.min_master_version
  database_encryption_key     = module.kms.gke_key_id
  enable_binary_authorization = var.enable_binary_authorization
  deletion_protection         = var.cluster_deletion_protection

  node_pools = var.node_pools
  labels     = local.labels
}

module "cloudsql" {
  source = "../../modules/cloudsql"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  network_id                 = module.network.network_id
  private_service_connection = module.network.private_service_connection

  tier                           = var.postgres_tier
  disk_size_gb                   = var.postgres_disk_size_gb
  availability_type              = var.postgres_availability_type
  max_connections                = var.postgres_max_connections
  read_replica_enabled           = var.postgres_read_replica
  deletion_protection            = var.postgres_deletion_protection
  transaction_log_retention_days = 7

  kms_key_id        = module.kms.cloudsql_key_id
  iam_database_user = module.iam.relay_iam_db_user

  labels = local.labels
}

module "memorystore" {
  source = "../../modules/memorystore"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  network_id                 = module.network.network_id
  private_service_connection = module.network.private_service_connection

  tier                       = var.redis_tier
  memory_size_gb             = var.redis_memory_size_gb
  transit_encryption_enabled = var.redis_transit_encryption

  labels = local.labels
}

module "artifact_registry" {
  source = "../../modules/artifact_registry"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  kms_key_id = module.kms.artifact_key_id
  readers = [
    "serviceAccount:${module.iam.node_service_account}",
  ]

  enable_binary_authorization = var.enable_binary_authorization
  attestor_public_key_pem     = var.attestor_public_key_pem

  labels = local.labels
}

module "secrets" {
  source = "../../modules/secrets"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix
  kms_key_id  = module.kms.secrets_key_id

  accessor_service_account = module.iam.external_secrets_service_account

  # The relay connects through the Cloud SQL Auth Proxy sidecar on localhost.
  # sslmode=disable is correct and safe here: the proxy itself establishes a
  # mutually authenticated TLS tunnel to the instance, and the plaintext hop is
  # inside the Pod's own network namespace. Setting sslmode=require would make
  # the relay try to negotiate TLS with the proxy's local listener, which does
  # not speak it.
  database_url = format(
    "postgres://%s:%s@127.0.0.1:5432/%s?sslmode=disable",
    module.cloudsql.app_user,
    urlencode(module.cloudsql.app_password),
    module.cloudsql.database_name,
  )

  read_database_url = var.postgres_read_replica ? format(
    "postgres://%s:%s@127.0.0.1:5433/%s?sslmode=disable",
    module.cloudsql.app_user,
    urlencode(module.cloudsql.app_password),
    module.cloudsql.database_name,
  ) : ""

  redis_url = module.memorystore.redis_url

  labels = local.labels
}

module "backup" {
  source = "../../modules/backup"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix
  cluster_id  = module.gke.cluster_id
  namespace   = var.namespace

  dr_bucket_location         = var.dr_bucket_location
  dr_retention_days          = var.dr_retention_days
  dr_bucket_retention_locked = var.dr_bucket_retention_locked

  minio_backup_service_account = module.iam.minio_backup_service_account

  labels = local.labels
}

module "edge" {
  source = "../../modules/edge"

  project_id  = var.project_id
  name_prefix = local.name_prefix

  domain          = var.domain
  relay_hostname  = var.relay_hostname
  admin_hostname  = var.admin_hostname
  dns_zone_name   = var.dns_zone_name
  create_dns_zone = var.create_dns_zone

  allowed_source_ranges          = var.allowed_source_ranges
  blocked_country_codes          = var.blocked_country_codes
  rate_limit_requests_per_minute = var.rate_limit_requests_per_minute
  iap_members                    = var.iap_members

  labels = local.labels
}

module "observability" {
  source = "../../modules/observability"

  project_id     = var.project_id
  region         = var.region
  name_prefix    = local.name_prefix
  cluster_name   = module.gke.cluster_name
  relay_hostname = var.relay_hostname

  notification_channels = var.notification_channels
  audit_retention_days  = var.audit_retention_days

  labels = local.labels
}
