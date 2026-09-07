# Architecture

## What this repository is

Buzz ships a good production Helm chart of its own
([`block/buzz`](https://github.com/block/buzz), `deploy/charts/buzz`). This
repository does not reimplement it. It is the **GCP enterprise layer around it**:

- **Terraform** for the landing zone — network, cluster, managed data services,
  keys, secrets, registry, edge, observability, backup.
- **An umbrella Helm chart** that depends on the upstream chart and supplies the
  GKE-native pieces upstream deliberately leaves to the platform.
- **`buzzctl`**, so standing an environment up and running it day-to-day is a
  handful of commands rather than a runbook of `gcloud` invocations.

Upstream owns how Buzz works. This repository owns how it runs here.

## The shape

```
Internet
   │
   ▼
Global external Gateway  (gke-l7-global-external-managed)
   ├── Cloud Armor           WAF, per-IP rate limit, source/geo allowlist
   ├── Certificate Manager   Google-managed certs, DNS-authorized
   ├── wss://buzz.<domain>       → relay        (no IAP: Nostr clients, no cookies)
   └── https://buzz-admin.<domain> → admin console (IAP)
   │
   ▼
┌─ private GKE Standard, Dataplane V2, Workload Identity ──────────────────┐
│                                                                          │
│  relay Deployment (3+)          MinIO StatefulSet (4)                    │
│   ├ relay          :3000 app    │  erasure-coded, PD-SSD                 │
│   │                :8080 health │  hard anti-affinity, own node pool     │
│   │                :9102 metrics│                                        │
│   └ cloud-sql-proxy  (sidecar)  └─ nightly mc mirror ──▶ GCS DR bucket   │
│                                                                          │
│  External Secrets Operator ──── reads ───▶ Secret Manager (CMEK)         │
│  GMP PodMonitoring ──────────── scrapes ─▶ Managed Prometheus            │
└──────────┬─────────────────────────────────┬─────────────────────────────┘
           │ private IP (PSA)                │ private IP (PSA)
   Cloud SQL PostgreSQL 17            Memorystore Redis
   regional HA, PITR, CMEK            STANDARD_HA, AUTH, TLS
```

## The three ports

The upstream chart exposes the relay on three ports, and confusing them is the
most common wiring error:

| Port | Serves | Used by |
|---|---|---|
| 3000 | WebSocket, REST, web bundle | clients, through the Gateway |
| 8080 | `/_liveness`, `/_readiness` | kubelet probes **and the LB health check** |
| 9102 | Prometheus `/metrics` | Google Managed Prometheus |

`HealthCheckPolicy` points the load balancer at **8080**, not 3000. Probing 3000
tells you the process is up. `/_readiness` on 8080 tells you Postgres, Redis and
object storage are all reachable — and it is where the relay reports the result
of its startup object-store conformance probe.

## Data, and where it lives

| Data | Store | Durability |
|---|---|---|
| Events, channels, membership, search | Cloud SQL PostgreSQL 17 | Regional HA, PITR, 30 automated backups |
| Media, git packs, git manifest pointers | MinIO in-cluster | Erasure-coded EC:2, nightly mirror to GCS |
| Presence, typing, pubsub fanout | Memorystore Redis | None needed — it is a bus, not a store |
| Cluster manifests and PVC contents | Backup for GKE | Nightly, retained per policy |

## The constraint that shapes everything

Buzz hosts git on object storage with no persistent filesystem, and serialises
concurrent pushes with a single S3 conditional write (`If-Match` on the
repository's manifest pointer, `If-None-Match: *` to create it). The relay probes
for that property at startup and **treats failure as fatal**.

Google Cloud Storage supports ETag preconditions on reads only. GCS therefore
cannot back Buzz — not as a degraded mode, but as a relay that never becomes
Ready. That is why this platform runs MinIO, and why a conformance probe runs
before Helm does.

Read [ADR-001](90-adr/ADR-001-object-storage.md) before changing anything about
object storage.

## Access control

Buzz has **no OIDC or SAML for humans**. Identity is a Nostr keypair. The
relay authenticates with NIP-42 over WebSocket and NIP-98 for the admin HTTP
API, and authorises against its `relay_members` table.

That is not a gap in this platform's configuration; it is what Buzz is. The
consequences for provisioning, de-provisioning and audit are spelled out in
[the security model](20-security-model.md), which is the document to hand a
security reviewer.

## Repository layout

```
terraform/
  bootstrap/          run once: APIs, state bucket, keyless CI identity
  modules/            network gke cloudsql memorystore kms secrets
                      artifact_registry edge iam observability backup
  environments/       dev staging prod — one Terraform root each
helm/buzz-gke/
  Chart.yaml          depends on oci://ghcr.io/block/buzz/charts/buzz 0.1.8
  values.yaml         structure and safe defaults
  values-<env>.yaml   reviewed per-environment choices
  templates/          Gateway, policies, PodMonitoring, ExternalSecrets,
                      MinIO, preflight, NetworkPolicy
  files/              storage_conformance.py — the object-store gate
config/<env>.yaml     public identity config: ownerPubkey, operators, rate limits
scripts/buzzctl       the CLI
policy/               conftest rules and the Binary Authorization policy
tests/                runnable checks; see tests/run_all.sh
docs/90-adr/          why things are the way they are
```

## How the layers meet

Terraform emits a single `platform` output. `buzzctl deploy` reads it, merges it
with `config/<env>.yaml`, and renders `values.generated.yaml`:

```
terraform output platform ─┐
                           ├─▶ render_values.py ─▶ values.generated.yaml ─┐
config/<env>.yaml ─────────┘                                              │
                                                                          ▼
helm/buzz-gke/values.yaml + values-<env>.yaml ─────────────────────▶ helm upgrade
```

Nothing project-specific is committed in the values files. A hostname, a project
id or a Cloud SQL connection name appearing in `values-prod.yaml` is a bug — it
belongs in Terraform's output, so the same reviewed values apply to every
environment.
