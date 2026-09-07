# Cloud SQL for PostgreSQL — the relay's event log and membership store.
#
# Private IP only. The relay reaches it through the Cloud SQL Auth Proxy
# running as a native sidecar in the relay Pod, which gives mutual TLS and
# (with --auto-iam-authn) removes the database password from the system
# entirely.

resource "random_id" "suffix" {
  byte_length = 3
}

resource "google_sql_database_instance" "this" {
  project = var.project_id
  # Cloud SQL reserves a deleted instance name for a week; the suffix keeps a
  # rebuild from failing on "instance name already in use".
  name             = "${var.name_prefix}-pg-${random_id.suffix.hex}"
  region           = var.region
  database_version = var.database_version

  deletion_protection = var.deletion_protection

  encryption_key_name = var.kms_key_id != "" ? var.kms_key_id : null

  settings {
    tier              = var.tier
    availability_type = var.availability_type
    disk_type         = "PD_SSD"
    disk_size         = var.disk_size_gb
    disk_autoresize   = true
    edition           = "ENTERPRISE"

    user_labels = var.labels

    ip_configuration {
      # No public IP. Nothing outside the VPC can open a socket to this instance.
      ipv4_enabled                                  = false
      private_network                               = var.network_id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      location                       = var.region
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = var.transaction_log_retention_days

      backup_retention_settings {
        retained_backups = var.backup_retention_days
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = false # relay connections all originate from the proxy
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      name  = "max_connections"
      value = var.max_connections
    }

    # Buzz runs sqlx migrations at startup and does heavy JSONB/full-text work;
    # logging slow statements is the first thing you want during an incident.
    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }

    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
  }

  depends_on = [var.private_service_connection]

  lifecycle {
    # A tier or disk change is intentional; an accidental instance replacement
    # would drop the entire event log.
    prevent_destroy = true
  }
}

resource "google_sql_database" "buzz" {
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  name     = var.database_name

  # Buzz stores UTF-8 text and does full-text search; anything else will bite.
  charset   = "UTF8"
  collation = "en_US.UTF8"
}

# ── Built-in role ────────────────────────────────────────────────────────────
# Kept even when IAM auth is the primary path: migrations, restores and
# break-glass access all need a password-authenticated role that does not
# depend on the proxy being healthy.
resource "random_password" "app_user" {
  length  = 32
  special = true
  # Excluded characters would need percent-encoding inside DATABASE_URL.
  override_special = "-_.~"
}

resource "google_sql_user" "app" {
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  name     = var.app_user
  password = random_password.app_user.result
}

# ── IAM database user ────────────────────────────────────────────────────────
resource "google_sql_user" "iam" {
  count = var.iam_database_user != "" ? 1 : 0

  project  = var.project_id
  instance = google_sql_database_instance.this.name
  # Cloud SQL registers a service account by its email with the domain suffix
  # stripped; passing the full email fails with "invalid user name".
  name = trimsuffix(var.iam_database_user, ".gserviceaccount.com")
  type = "CLOUD_IAM_SERVICE_ACCOUNT"
}

# ── Read replica ─────────────────────────────────────────────────────────────
resource "google_sql_database_instance" "replica" {
  count = var.read_replica_enabled ? 1 : 0

  project              = var.project_id
  name                 = "${var.name_prefix}-pg-${random_id.suffix.hex}-replica"
  region               = var.region
  database_version     = var.database_version
  master_instance_name = google_sql_database_instance.this.name
  deletion_protection  = var.deletion_protection

  encryption_key_name = var.kms_key_id != "" ? var.kms_key_id : null

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = var.tier
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_autoresize   = true
    edition           = "ENTERPRISE"
    user_labels       = var.labels

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    insights_config {
      query_insights_enabled = true
    }
  }
}
