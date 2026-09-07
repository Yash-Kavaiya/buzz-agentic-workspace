# ADR-005: Memorystore in-transit encryption, and its fallback

- **Status**: Accepted, with a validation step that must be performed
- **Date**: 2026-09-07
- **Decision**: Memorystore transit encryption is **on** by default. The relay
  dials `rediss://` with the Google-managed CA mounted from a ConfigMap. If the
  handshake cannot be made to work, the documented fallback is AUTH-only on the
  private VPC — chosen deliberately, not discovered in production.

## Context

Buzz uses Redis as its pubsub, presence and typing backplane. It is required as
soon as `replicaCount > 1`: `buzz-pubsub` fans events between relay replicas
through it.

The relay's Redis client is compiled with rustls
(`redis = { features = [..., "tokio-rustls-comp"] }` in the upstream
`Cargo.toml`), and the crate tree includes `rustls-native-certs` — meaning TLS
verification reads the **system trust store**.

Memorystore's in-transit encryption terminates TLS with a **Google-managed
private CA**. That CA is in no public trust store. A `rediss://` connection from
a stock container image therefore fails certificate verification.

## Decision

Provision the CA alongside the credentials and point the process at it:

1. `terraform/modules/memorystore` outputs `server_ca_cert`.
2. `buzzctl secrets init` fetches it and caches it locally.
3. `scripts/lib/render_values.py` passes it into the chart, which renders
   `helm/buzz-gke/templates/redis-ca-configmap.yaml`, mounts it at
   `/etc/buzz/redis-ca`, and sets `SSL_CERT_FILE` and `SSL_CERT_DIR` in the
   relay's environment.

`transit_encryption_enabled` is a Terraform variable, not a hardcoded value, and
its documentation says why before it says what.

### The validation step

**This has not been verified against a live Memorystore instance.** The trust
chain is reasoned from the dependency tree, not observed. Before promoting past
dev:

```
buzzctl preflight <env>
```

must show the Redis handshake succeeding. If it does not — if `rustls-native-certs`
does not pick up `SSL_CERT_FILE`, or the bundle format is not what it expects —
then:

- set `redis_transit_encryption = false` in that environment's tfvars,
- re-apply and redeploy,
- and record the decision, because it is a real reduction in posture.

With the flag off, traffic to Redis is authenticated (AUTH is enabled
unconditionally, in every configuration) but not encrypted, on a private VPC
where the only things that can route to the instance are the cluster's own
nodes. `NOTES.txt` prints a note whenever a multi-replica deployment is running
in that mode, so it stays visible rather than becoming the silent default.

## Alternatives considered

**Bake the CA into a custom relay image.** Upstream's Dockerfile has an
`EXTRA_CA_CERTS` build argument for exactly this. Rejected as the default: it
means maintaining a fork of the image build for every upstream release, and the
digest we deploy would no longer correspond to an upstream artifact — which
undercuts ADR-004's supply-chain story.

**An stunnel sidecar terminating TLS locally.** Works, and moves the trust
problem into a component we configure. Rejected as unnecessary complexity until
the simple approach is shown to fail; it remains the escape hatch if AUTH-only
is unacceptable and the CA mount cannot be made to work.

**In-cluster Redis instead of Memorystore.** Removes the problem entirely, and
adds Redis operations, HA and failover to the platform's burden. Not worth it
for a component whose loss costs presence and in-flight fanout but no durable
data.

## Consequences

- Redis is a cache and a bus, not a store of record. Losing it drops presence and
  fanout; the event log in Postgres and the media and git state in object storage
  are unaffected. That bounds how much this decision can cost.
- `maxmemory-policy` is `allkeys-lru`: presence and typing keys are disposable,
  and evicting is better than refusing writes when memory fills.
- The preflight is the gate. Do not promote an environment whose Redis handshake
  has not been observed working.
