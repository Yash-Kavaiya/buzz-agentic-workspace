# ADR-003: Private cluster, public hardened edge

- **Status**: Accepted
- **Date**: 2026-09-07
- **Decision**: Private GKE Standard cluster with no public node IPs and no
  public control-plane endpoint. Exactly one ingress path: a global external
  Gateway with Cloud Armor and Google-managed certificates. IAP protects the
  admin console only.

## Context

Buzz clients are desktop and CLI applications used by staff who are not always
on the corporate network. The workspace has to be reachable from a laptop on a
home connection, which rules out an internal-only load balancer unless everyone
is on VPN.

That is an ingress requirement, not a reason to expose anything else.

## Decision

**Data plane in, one way.** A global external Gateway
(`gke-l7-global-external-managed`) on a reserved anycast IP, with certificates
from Certificate Manager bound by the `networking.gke.io/certmap` annotation. A
Cloud Armor policy sits in front: source allowlist, optional geo denial,
preconfigured OWASP signatures at sensitivity 1, and a per-IP rate-based ban.

WAF sensitivity is deliberately at its least aggressive setting. Buzz carries
signed Nostr events and base64 media in request bodies; aggressive SQLi and XSS
heuristics generate false positives on that traffic, and a WAF that blocks real
messages gets turned off entirely.

**The backend timeout is the setting that matters most.** Google's default
backend timeout is 30 seconds, which severs idle WebSockets. Buzz clients hold
connections open for hours. `GCPBackendPolicy.spec.default.timeoutSec: 3600`
(`helm/buzz-gke/templates/backendpolicy.yaml`) is why the deployment does not
present as "clients randomly disconnect".

**Health checks target the private health listener.** The relay serves the app
on 3000 and health on 8080. Probing 3000 tells you the process is up; probing
`/_readiness` on 8080 tells you Postgres, Redis and object storage are all
reachable — and it is where the relay reports its object-store conformance
result. `HealthCheckPolicy` points at 8080 for that reason.

**Nothing else is exposed.** Nodes have no external IPs and egress through Cloud
NAT. The control plane has no public endpoint by default; reach it from a
bastion in the VPC, Cloud VPN, or the GKE Connect gateway. Cloud SQL and
Memorystore are private-IP only over Private Service Access. `dev` may set
`enable_public_control_plane = true` for laptop access, restricted to
`master_authorized_networks`; staging and prod may not.

**IAP protects the admin console, and only the admin console.** The moderation
console gets its own hostname with its own backend, so IAP can be applied to it
alone. IAP cannot front the relay: Buzz desktop and CLI clients authenticate
with Nostr keys over a WebSocket and carry no Google session cookie, so an
IAP-protected relay would reject every legitimate client. Splitting by hostname
gives two backends; splitting by path would not.

## Consequences

- The relay is reachable from the public internet by anyone who gets past Cloud
  Armor. **Relay-level access control is what actually keeps people out** —
  `requireRelayMembership`, `pubkeyAllowlist`, and the membership roster. See
  `docs/20-security-model.md`. Cloud Armor is depth, not the boundary.
- `allowed_source_ranges` defaults to `0.0.0.0/0`, which is a *choice* recorded
  in `terraform/environments/prod/terraform.tfvars` with a comment. Narrowing it
  to corporate egress is the single largest reduction in attack surface
  available, and costs remote staff their access.
- Certificate renewal depends on the DNS authorization records staying in the
  zone. Pruning them breaks renewal 90 days later, silently. There is an alert
  for certificate expiry within 20 days (`terraform/modules/observability`).
- A private control plane means CI cannot `kubectl apply` without a network
  path. The `terraform-apply` workflow runs infrastructure only; `buzzctl deploy`
  is run by an operator with VPN or bastion access.
