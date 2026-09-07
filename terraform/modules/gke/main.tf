# Private regional GKE Standard cluster for Buzz.
#
# Standard rather than Autopilot because MinIO needs control over disk type,
# node placement and anti-affinity that Autopilot does not give us, and because
# the relay pods run a native sidecar with a specific security context.
#
# Security posture baked in here:
#   - private nodes, no external IPs, egress through Cloud NAT
#   - private control plane (public endpoint off by default)
#   - Workload Identity — no node-level credential is ever a pod's credential
#   - Dataplane V2 (eBPF) so NetworkPolicy is enforced and logged
#   - Shielded nodes with secure boot and integrity monitoring
#   - application-layer etcd Secret encryption under a CMEK
#   - Binary Authorization so only attested, mirrored images run
#   - a dedicated least-privilege node service account

# master_authorized_networks_config is rendered by a dynamic block, which a static analyser cannot evaluate, so this rule fires
# whatever the input. The dangerous case the rule exists to catch — a public
# endpoint with no allowlist — is instead refused outright by the precondition
# at the bottom of this resource, and asserted again in
# policy/conftest/terraform.rego and tests/lint_terraform.py against the values
# that will actually be applied.
# trivy:ignore:AVD-GCP-0061
resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.name_prefix
  location = var.region

  # The default pool exists only so the cluster can be created; every real
  # workload lands on the managed pools below.
  remove_default_node_pool = true
  initial_node_count       = 1

  min_master_version    = var.min_master_version
  deletion_protection   = var.deletion_protection
  network               = var.network_id
  subnetwork            = var.subnet_id
  networking_mode       = "VPC_NATIVE"
  datapath_provider     = "ADVANCED_DATAPATH" # Dataplane V2
  enable_shielded_nodes = true

  resource_labels = var.labels

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = !var.enable_public_endpoint
    master_ipv4_cidr_block  = var.master_cidr

    master_global_access_config {
      enabled = true
    }
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_networks) > 0 ? [1] : []
    content {
      gcp_public_cidrs_access_enabled = false

      dynamic "cidr_blocks" {
        for_each = var.master_authorized_networks
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  database_encryption {
    state    = "ENCRYPTED"
    key_name = var.database_encryption_key
  }

  dynamic "binary_authorization" {
    for_each = var.enable_binary_authorization ? [1] : []
    content {
      evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
    }
  }

  # NetworkPolicy enforcement comes from Dataplane V2, so the legacy Calico
  # addon must stay disabled — enabling both is a supported-config error.
  network_policy {
    enabled = false
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gcs_fuse_csi_driver_config {
      enabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
    dns_cache_config {
      enabled = true
    }
    gke_backup_agent_config {
      enabled = var.enable_backup_agent
    }
  }

  # Gateway API is how the relay is exposed; without this the GatewayClass
  # resources never appear and the Helm release blocks on a missing CRD.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  # Google Managed Prometheus. The chart ships a PodMonitoring rather than a
  # ServiceMonitor precisely so this is the only monitoring stack required.
  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "APISERVER",
      "CONTROLLER_MANAGER",
      "SCHEDULER",
      "STORAGE",
      "HPA",
      "POD",
      "DAEMONSET",
      "DEPLOYMENT",
      "STATEFULSET",
    ]
    managed_prometheus {
      enabled = true
    }
  }

  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
      "APISERVER",
      "CONTROLLER_MANAGER",
      "SCHEDULER",
    ]
  }

  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_ENTERPRISE"
  }

  cost_management_config {
    enabled = true
  }

  maintenance_policy {
    recurring_window {
      start_time = var.maintenance_start_time
      end_time   = timeadd(var.maintenance_start_time, "4h")
      recurrence = var.maintenance_recurrence
    }
  }

  # Node auto-provisioning is off: pool shapes here are deliberate (MinIO in
  # particular must not land on an arbitrary machine type).
  cluster_autoscaling {
    enabled = false
  }

  lifecycle {
    ignore_changes = [
      # The default pool is removed post-create; its count drifting is expected.
      initial_node_count,
    ]

    # A public control-plane endpoint with no authorized networks puts the
    # Kubernetes API server on the internet for anyone to reach. The two
    # settings are individually reasonable and catastrophic together, which is
    # exactly the combination a reviewer skims past — so refuse it at plan time
    # rather than discovering it in a scan afterwards.
    precondition {
      condition = !var.enable_public_endpoint || length(var.master_authorized_networks) > 0
      error_message = join(" ", [
        "enable_public_endpoint is true but master_authorized_networks is empty,",
        "which would expose the Kubernetes API server to the entire internet.",
        "Either set master_authorized_networks to the CIDRs that need API access",
        "(your office egress, a bastion, the CI runner), or set",
        "enable_public_control_plane = false and reach the cluster through a",
        "bastion, Cloud VPN, or the GKE Connect gateway.",
      ])
    }
  }
}

resource "google_container_node_pool" "this" {
  for_each = var.node_pools

  project  = var.project_id
  name     = "${var.name_prefix}-${each.key}"
  location = var.region
  cluster  = google_container_cluster.this.name

  # Regional cluster: node_count is per zone, so the effective floor is
  # min_count * (number of zones in the region).
  initial_node_count = coalesce(each.value.initial_count, each.value.min_count)

  autoscaling {
    min_node_count  = each.value.min_count
    max_node_count  = each.value.max_count
    location_policy = "BALANCED"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = each.value.machine_type
    disk_type    = each.value.disk_type
    disk_size_gb = each.value.disk_size_gb
    spot         = each.value.spot

    service_account = var.node_service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    tags   = [var.node_tag]
    labels = merge(var.labels, each.value.labels, { "buzz.io/pool" = each.key })

    local_ssd_count = each.value.local_ssd_count

    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      # GKE_METADATA is what makes Workload Identity work and simultaneously
      # blocks pods from reading the node's own instance metadata credentials.
      mode = "GKE_METADATA"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    gcfs_config {
      enabled = true # image streaming; meaningfully faster relay cold starts
    }
  }

  lifecycle {
    # Autoscaling owns the live count; Terraform must not fight it on apply.
    ignore_changes = [initial_node_count]
  }
}
