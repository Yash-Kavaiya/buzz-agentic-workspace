# The public edge: static IP, managed certificates, Cloud Armor, DNS, IAP.
#
# The Gateway created by the Helm chart binds to the static IP and certificate
# map created here, and the GCPBackendPolicy references the Cloud Armor policy
# by name. Terraform owns the Google-side objects; Kubernetes owns the routing.

resource "google_compute_global_address" "gateway" {
  project      = var.project_id
  name         = "${var.name_prefix}-gateway-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
  description  = "Anycast IP for the Buzz relay and admin console."
}

# ── DNS ──────────────────────────────────────────────────────────────────────
resource "google_dns_managed_zone" "this" {
  count = var.create_dns_zone ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-zone"
  dns_name    = "${var.domain}."
  description = "Buzz workspace zone (${var.name_prefix})."
  labels      = var.labels

  dnssec_config {
    state = "on"
  }
}

locals {
  zone_name = var.create_dns_zone ? google_dns_managed_zone.this[0].name : var.dns_zone_name
  manage_dns = local.zone_name != ""
}

resource "google_dns_record_set" "relay" {
  count = local.manage_dns ? 1 : 0

  project      = var.project_id
  managed_zone = local.zone_name
  name         = "${var.relay_hostname}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.gateway.address]
}

resource "google_dns_record_set" "admin" {
  count = local.manage_dns ? 1 : 0

  project      = var.project_id
  managed_zone = local.zone_name
  name         = "${var.admin_hostname}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.gateway.address]
}

# ── Certificates ─────────────────────────────────────────────────────────────
# DNS authorization rather than load-balancer authorization, so the certificate
# can be issued and renewed before the Gateway exists and without depending on
# the data path being healthy.
resource "google_certificate_manager_dns_authorization" "relay" {
  project = var.project_id
  name    = "${var.name_prefix}-relay-dnsauth"
  domain  = var.relay_hostname
  labels  = var.labels
}

resource "google_certificate_manager_dns_authorization" "admin" {
  project = var.project_id
  name    = "${var.name_prefix}-admin-dnsauth"
  domain  = var.admin_hostname
  labels  = var.labels
}

resource "google_dns_record_set" "relay_auth" {
  count = local.manage_dns ? 1 : 0

  project      = var.project_id
  managed_zone = local.zone_name
  name         = google_certificate_manager_dns_authorization.relay.dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.relay.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.relay.dns_resource_record[0].data]
}

resource "google_dns_record_set" "admin_auth" {
  count = local.manage_dns ? 1 : 0

  project      = var.project_id
  managed_zone = local.zone_name
  name         = google_certificate_manager_dns_authorization.admin.dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.admin.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.admin.dns_resource_record[0].data]
}

resource "google_certificate_manager_certificate" "relay" {
  project = var.project_id
  name    = "${var.name_prefix}-relay-cert"
  labels  = var.labels

  managed {
    domains            = [var.relay_hostname]
    dns_authorizations = [google_certificate_manager_dns_authorization.relay.id]
  }
}

resource "google_certificate_manager_certificate" "admin" {
  project = var.project_id
  name    = "${var.name_prefix}-admin-cert"
  labels  = var.labels

  managed {
    domains            = [var.admin_hostname]
    dns_authorizations = [google_certificate_manager_dns_authorization.admin.id]
  }
}

resource "google_certificate_manager_certificate_map" "this" {
  project = var.project_id
  name    = "${var.name_prefix}-certmap"
  labels  = var.labels
}

resource "google_certificate_manager_certificate_map_entry" "relay" {
  project      = var.project_id
  name         = "${var.name_prefix}-relay-entry"
  map          = google_certificate_manager_certificate_map.this.name
  hostname     = var.relay_hostname
  certificates = [google_certificate_manager_certificate.relay.id]
}

resource "google_certificate_manager_certificate_map_entry" "admin" {
  project      = var.project_id
  name         = "${var.name_prefix}-admin-entry"
  map          = google_certificate_manager_certificate_map.this.name
  hostname     = var.admin_hostname
  certificates = [google_certificate_manager_certificate.admin.id]
}

# ── Cloud Armor ──────────────────────────────────────────────────────────────
# Rule priority order matters: allowlist first, then geo denies, then WAF
# signatures, then the rate limiter, then the default action.
resource "google_compute_security_policy" "this" {
  project     = var.project_id
  name        = "${var.name_prefix}-armor"
  description = "Edge policy for the Buzz relay and admin console."
  type        = "CLOUD_ARMOR"

  advanced_options_config {
    json_parsing = "STANDARD"
    log_level    = "NORMAL"
  }

  # 1000 — source allowlist. When allowed_source_ranges is the default 0.0.0.0/0
  # this is a no-op allow that simply lets traffic reach the later rules.
  rule {
    action      = "allow"
    priority    = 1000
    description = "Permitted source ranges."
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = var.allowed_source_ranges
      }
    }
  }

  # 900 — geo denial, evaluated before the allowlist so a blocked country is
  # blocked even if its range appears in allowed_source_ranges.
  dynamic "rule" {
    for_each = length(var.blocked_country_codes) > 0 ? [1] : []
    content {
      action      = "deny(403)"
      priority    = 900
      description = "Geographic denial."
      match {
        expr {
          expression = join(" || ", [for c in var.blocked_country_codes : "origin.region_code == '${c}'"])
        }
      }
    }
  }

  # 1100-1300 — OWASP signatures at the lowest false-positive sensitivity.
  dynamic "rule" {
    for_each = var.enable_waf_rules ? {
      1100 = "sqli-v33-stable"
      1200 = "xss-v33-stable"
      1300 = "lfi-v33-stable"
      1400 = "rce-v33-stable"
    } : {}
    content {
      action      = "deny(403)"
      priority    = rule.key
      description = "Preconfigured WAF: ${rule.value}"
      match {
        expr {
          expression = "evaluatePreconfiguredWaf('${rule.value}', {'sensitivity': 1})"
        }
      }
      preview = false
    }
  }

  # 2000 — per-IP rate limiting. throttle rather than ban on first breach so a
  # busy office NAT degrades instead of going dark.
  rule {
    action      = "rate_based_ban"
    priority    = 2000
    description = "Per-source-IP request ceiling."

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action   = "allow"
      exceed_action    = "deny(429)"
      enforce_on_key   = "IP"
      ban_duration_sec = var.rate_limit_ban_seconds

      rate_limit_threshold {
        count        = var.rate_limit_requests_per_minute
        interval_sec = 60
      }

      ban_threshold {
        count        = var.rate_limit_requests_per_minute * 3
        interval_sec = 60
      }
    }
  }

  # 2147483647 — required default rule.
  rule {
    action      = length(var.allowed_source_ranges) == 1 && contains(var.allowed_source_ranges, "0.0.0.0/0") ? "allow" : "deny(403)"
    priority    = 2147483647
    description = "Default action."
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

# ── IAP for the admin console ────────────────────────────────────────────────
# IAP fronts only the admin hostname. It cannot front the relay: Buzz desktop
# and CLI clients authenticate with Nostr keys over a WebSocket and carry no
# Google session cookie, so an IAP-protected relay would reject every client.
resource "google_iap_web_backend_service_iam_member" "admin" {
  for_each = var.enable_iap_for_admin ? toset(var.iap_members) : toset([])

  project = var.project_id
  # The backend service is created by GKE from the admin HTTPRoute's Service.
  # Its generated name is surfaced by `buzzctl status`; set it here once the
  # Gateway has reconciled, or manage this binding with buzzctl instead.
  web_backend_service = "${var.name_prefix}-admin-backend"
  role                = "roles/iap.httpsResourceAccessor"
  member              = each.value
}
