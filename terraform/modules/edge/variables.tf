variable "project_id" {
  description = "GCP project that hosts this environment."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix for this environment, e.g. buzz-prod."
  type        = string
}

variable "domain" {
  description = "Apex domain the workspace lives under, e.g. example.com."
  type        = string
}

variable "relay_hostname" {
  description = "Host clients connect to. Becomes relayUrl as wss://<host>."
  type        = string
}

variable "admin_hostname" {
  description = "Host serving the moderation console. Fronted by IAP; never the same host as the relay."
  type        = string
}

variable "dns_zone_name" {
  description = "Existing Cloud DNS managed zone name. Empty creates one for var.domain."
  type        = string
  default     = ""
}

variable "create_dns_zone" {
  description = "Create the Cloud DNS zone rather than using an existing one."
  type        = bool
  default     = false
}

variable "allowed_source_ranges" {
  description = <<-EOT
    CIDRs permitted to reach the relay. The default is open, which is correct
    for a workforce on residential and mobile networks. Narrow it to the
    corporate egress ranges if every client is on the network or VPN — that one
    change is the single biggest reduction in attack surface available here.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "blocked_country_codes" {
  description = "ISO 3166-1 alpha-2 codes to deny outright. Empty disables geo blocking."
  type        = list(string)
  default     = []
}

variable "rate_limit_requests_per_minute" {
  description = <<-EOT
    Per-source-IP request ceiling at the edge. This counts HTTP requests
    (including the WebSocket upgrade and every media/git call), not messages —
    Buzz's own BUZZ_RATE_LIMIT_* settings govern message rates once connected.
    Keep it well above normal client behaviour; a NAT'd office egresses from one IP.
  EOT
  type        = number
  default     = 1200
}

variable "rate_limit_ban_seconds" {
  description = <<-EOT
    How long a source IP stays banned after it blows past three times the
    per-minute ceiling. Kept short: a banned office NAT takes every client
    behind it offline, and a WebSocket client that is banned mid-session
    reconnects into the ban.
  EOT
  type        = number
  default     = 300
}

variable "enable_waf_rules" {
  description = <<-EOT
    Apply the preconfigured OWASP rule sets. Sensitivity is kept at 1 (the
    highest-confidence signatures only): Buzz carries signed Nostr events and
    base64 media in request bodies, and aggressive SQLi/XSS heuristics generate
    false positives on that traffic.
  EOT
  type        = bool
  default     = true
}

variable "enable_iap_for_admin" {
  description = "Put the admin console behind Identity-Aware Proxy."
  type        = bool
  default     = true
}

variable "iap_members" {
  description = "Members allowed through IAP to the admin console, e.g. group:buzz-operators@example.com."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
