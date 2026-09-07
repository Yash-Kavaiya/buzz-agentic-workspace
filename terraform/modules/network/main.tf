# VPC for the Buzz platform.
#
# Shape: one custom-mode VPC, one regional VPC-native subnet with secondary
# ranges for pods and services, Cloud NAT for egress (nodes have no external
# IPs), and a Private Service Access allocation that Cloud SQL and Memorystore
# both draw their private IPs from.
#
# Deliberately absent: any 0.0.0.0/0 ingress rule. The only path in is the
# Google-managed load balancer created by the Gateway, whose health checks and
# data plane arrive from Google's own ranges (allowed explicitly below).

resource "google_compute_network" "vpc" {
  project                         = var.project_id
  name                            = "${var.name_prefix}-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
  description                     = "Buzz platform VPC (${var.name_prefix})."
}

resource "google_compute_subnetwork" "gke" {
  project       = var.project_id
  name          = "${var.name_prefix}-gke"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Required for Workload Identity + no-external-IP nodes to reach Google APIs.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${var.name_prefix}-pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "${var.name_prefix}-services"
    ip_cidr_range = var.services_cidr
  }

  # VPC flow logs are the only way to answer "who talked to what" after an
  # incident. Sampled at 50% to keep the log bill sane.
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ── Egress ───────────────────────────────────────────────────────────────────
# Nodes are private (no external IP). Cloud NAT gives them outbound reach for
# image pulls from Artifact Registry mirrors and for agent LLM API calls.
resource "google_compute_router" "router" {
  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  project = var.project_id
  name    = "${var.name_prefix}-nat"
  region  = var.region
  router  = google_compute_router.router.name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name = google_compute_subnetwork.gke.id
    source_ip_ranges_to_nat = [
      "PRIMARY_IP_RANGE",
      "LIST_OF_SECONDARY_IP_RANGES",
    ]
    secondary_ip_range_names = [
      one([for r in google_compute_subnetwork.gke.secondary_ip_range : r.range_name if endswith(r.range_name, "-pods")]),
    ]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── Private Service Access ───────────────────────────────────────────────────
# Cloud SQL and Memorystore are reached over private IPs allocated from this
# block and peered into the VPC. Without it both services would need public IPs.
resource "google_compute_global_address" "psa" {
  project       = var.project_id
  name          = "${var.name_prefix}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.psa_prefix_length
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
}

# Without this the peering advertises only the local subnet, and the GKE
# control plane cannot reach Cloud SQL for the managed-service integrations.
resource "google_compute_network_peering_routes_config" "psa" {
  project              = var.project_id
  peering              = google_service_networking_connection.psa.peering
  network              = google_compute_network.vpc.name
  import_custom_routes = true
  export_custom_routes = true
}

# ── Firewall ─────────────────────────────────────────────────────────────────
resource "google_compute_firewall" "allow_health_checks" {
  project     = var.project_id
  name        = "${var.name_prefix}-allow-google-health-checks"
  network     = google_compute_network.vpc.name
  description = "Google front-end and health-check ranges to the relay and MinIO ports."
  direction   = "INGRESS"
  priority    = 1000

  # Fixed, documented Google ranges for LB data plane and health checking.
  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
    "209.85.152.0/22",
    "209.85.204.0/22",
  ]

  target_tags = ["${var.name_prefix}-node"]

  allow {
    protocol = "tcp"
    ports    = ["3000", "8080", "9102"]
  }
}

resource "google_compute_firewall" "allow_control_plane_to_webhooks" {
  project     = var.project_id
  name        = "${var.name_prefix}-allow-cp-webhooks"
  network     = google_compute_network.vpc.name
  description = "Private control plane to admission/conversion webhooks on nodes (External Secrets, Gateway policies)."
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.master_cidr]
  target_tags   = ["${var.name_prefix}-node"]

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "9443", "10250", "15017"]
  }
}

resource "google_compute_firewall" "allow_intra_node" {
  project     = var.project_id
  name        = "${var.name_prefix}-allow-intra-node"
  network     = google_compute_network.vpc.name
  description = "Node-to-node traffic within the cluster (MinIO erasure set, relay pubsub)."
  direction   = "INGRESS"
  priority    = 1000

  source_tags = ["${var.name_prefix}-node"]
  target_tags = ["${var.name_prefix}-node"]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# Deny-all egress with explicit allows would be the strongest posture, but it
# breaks image pulls and agent LLM calls in ways that are hard to debug. We
# instead deny the classic exfiltration ports outright and rely on Kubernetes
# NetworkPolicy (Dataplane V2) for pod-level egress control.
resource "google_compute_firewall" "deny_smtp_egress" {
  project     = var.project_id
  name        = "${var.name_prefix}-deny-smtp-egress"
  network     = google_compute_network.vpc.name
  description = "No workload in this platform legitimately sends mail directly."
  direction   = "EGRESS"
  priority    = 900

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["${var.name_prefix}-node"]

  deny {
    protocol = "tcp"
    ports    = ["25", "465", "587"]
  }
}
