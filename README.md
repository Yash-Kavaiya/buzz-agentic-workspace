# buzz-agentic-workspace

Enterprise self-hosting for [Buzz](https://github.com/block/buzz) — Block's
open-source, agent-native workspace — on Google Kubernetes Engine.

Buzz ships its own production Helm chart. **This repository does not reimplement
it.** It is the GCP layer around it: Terraform for the landing zone, an umbrella
chart supplying the GKE-native pieces upstream leaves to the platform, and a
`buzzctl` CLI so standing up an environment and running it day-to-day is a
handful of commands.

```sh
buzzctl bootstrap --project my-project --repo owner/repo
buzzctl infra apply prod
buzzctl secrets init prod
buzzctl images mirror prod
buzzctl preflight prod
buzzctl deploy prod
buzzctl verify prod
```

---

## Read this before choosing object storage

On Google Cloud the obvious store is GCS through its S3-compatible API.
**It cannot back Buzz.**

Buzz hosts git repositories on object storage with no persistent filesystem, and
serialises concurrent pushes with a single S3 conditional write — `If-Match` on
the repository's manifest pointer, `If-None-Match: *` to create it. GCS supports
ETag preconditions on *read* requests only.

This does not degrade gracefully. The relay probes for the property at startup
and treats failure as fatal, so a GCS-backed deployment is a relay that starts
cleanly, never becomes Ready, and logs a conformance report most operators have
never seen.

So this platform runs **distributed MinIO in-cluster**, with GCS as a
disaster-recovery mirror target only. The reasoning, the evidence and the
alternatives are in
[ADR-001](docs/90-adr/ADR-001-object-storage.md), and the constraint is enforced
rather than documented: a conformance probe runs before Helm does, and
`tests/test_storage_conformance.py` proves that probe detects a GCS-shaped store.

## Read this before promising SSO

**Buzz has no OIDC or SAML authentication for humans.** Identity is a Nostr
keypair; the relay authenticates with NIP-42 and authorises against its own
membership roster.

Access is granted with `buzzctl onboard user` and revoked with
`buzzctl offboard`. Disabling someone's Google account does **not** remove their
Buzz access — removal has to be an explicit step in your leaver process.

[The security model](docs/20-security-model.md) states this plainly, along with
the layered mitigations, and is the document to hand a security reviewer.

---

## What gets built

```
Internet ──▶ Global external Gateway (Cloud Armor, managed certs)
             ├── wss://buzz.<domain>        → relay
             └── https://buzz-admin.<domain> → admin console (IAP)
                     │
      ┌──────────────▼─── private GKE Standard, Dataplane V2 ──────────────┐
      │  relay (3+) + cloud-sql-proxy sidecar    MinIO (4, erasure-coded)  │
      │  External Secrets ◀── Secret Manager     GMP PodMonitoring          │
      └───────┬──────────────────────────────────────┬────────────────────┘
              │ private IP                           │ private IP
    Cloud SQL PostgreSQL 17 (regional HA, PITR)   Memorystore Redis (HA, AUTH)
```

Security posture, in short: private nodes and private control plane, Workload
Identity throughout, CMEK on etcd/database/secrets/images, Binary Authorization
with digest-pinned images, default-deny NetworkPolicy on an enforcing datapath,
Cloud Armor at the edge, audit logs exported to BigQuery, and no service-account
key anywhere in the system.

## Layout

| Path | What |
|---|---|
| `terraform/bootstrap` | Run once: APIs, state bucket, keyless CI identity |
| `terraform/modules` | network · gke · cloudsql · memorystore · kms · secrets · artifact_registry · edge · iam · observability · backup |
| `terraform/environments` | `dev` `staging` `prod` — one root, one state each |
| `helm/buzz-gke` | Umbrella chart on upstream `buzz` 0.1.8 |
| `helm/buzz-gke/files` | `storage_conformance.py` — the object-store gate |
| `config/<env>.yaml` | Public identity config: owner, operators, rate limits |
| `scripts/buzzctl` | The CLI |
| `policy/` | conftest rules; the ADRs made machine-checkable |
| `tests/` | `./tests/run_all.sh` |
| `docs/` | Architecture, security, runbooks, backup/DR, onboarding, ADRs |

## Documentation

| | |
|---|---|
| [Architecture](docs/00-architecture.md) | How the pieces fit, and the three ports that matter |
| [Prerequisites](docs/01-prerequisites.md) | Tools, roles, CIDRs, DNS, cost |
| [Quickstart](docs/10-quickstart.md) | dev, end to end, in about 45 minutes |
| [Security model](docs/20-security-model.md) | For the reviewer. Includes the known limitations |
| [Runbooks](docs/30-runbooks.md) | When something is wrong |
| [Backup and DR](docs/40-backup-dr.md) | What is protected, and how to restore it |
| [Onboarding](docs/50-onboarding-users-agents.md) | People, agents, operators |
| [ADRs](docs/90-adr/) | Why things are the way they are |

## `buzzctl`

```
bootstrap                 APIs, state bucket, CI identity
infra    plan|apply|destroy|output ENV
secrets  init|status ENV
images   mirror ENV
preflight ENV             cluster, policy enforcement, secrets, object store
deploy   ENV
verify   ENV              pods, NIP-11, WebSocket + NIP-42, metrics, roster
onboard  user|agent ENV
offboard ENV
members  ENV
rotate   hmac|minio ENV
backup   now|verify|enable ENV
status | logs | doctor ENV
keygen | npub | hex | version
```

`buzzctl help` for the detail. `doctor` is the one to reach for first when
something is wrong — it checks the failure modes this platform actually
produces, in the order they occur, and explains each rather than just reporting
it.

## Checks

```sh
./tests/run_all.sh
```

Runs on any machine, in seconds, and skips gracefully what it cannot run.
Worth knowing what it actually proves:

- The object-store conformance probe **admits** a conforming store and
  **rejects** one that ignores conditional writes — the central claim of the
  design, tested rather than asserted.
- secp256k1 derivation against published vectors, NIP-19 round-trip against the
  reference vector, and refusal of a corrupted npub or a private `nsec`.
- The Cloud SQL proxy renders as a native sidecar, not a blocking init
  container — the difference between a working pod and one stuck in `Init`
  forever.
- Terraform invariants: private nodes, Workload Identity, CMEK, Dataplane V2, no
  public database IP, Redis AUTH, buckets locked down.

CI additionally runs the real `terraform validate`, `helm template`,
`kubeconform` and `conftest`.

## Versions

| | |
|---|---|
| Buzz | v0.5.23 (`helm/buzz-gke` `appVersion`) |
| Upstream chart | `oci://ghcr.io/block/buzz/charts/buzz` 0.1.8 |
| Kubernetes | ≥ 1.29 — required for the native sidecar |
| Terraform | ≥ 1.6, `hashicorp/google` ~> 6.13 |

The upstream chart's `appVersion` is `0.1.0` while the product is at v0.5.23, so
the default image tag is not usable. Images are always deployed by digest;
`buzzctl deploy` refuses to run without one.

## Licence

This repository is the organisation's own deployment code. Buzz itself is
Apache-2.0. MinIO's community edition is AGPL-3.0 and is run here as an
unmodified network service — see [ADR-001](docs/90-adr/ADR-001-object-storage.md)
if that matters to your policy.
