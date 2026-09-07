# Runbooks

Start with `buzzctl doctor <env>`. It checks the failure modes this platform
actually produces, in the order they occur, and explains each one. The runbooks
below are what to do once you know which one you have.

---

## The relay is not becoming Ready

The single most common cause, and the least obvious.

```sh
buzzctl doctor <env>
kubectl -n buzz logs deploy/buzz -c relay --tail=200 | grep -i conformance
```

### Object-store conformance failure

The relay probes the object store for linearizable conditional writes at
startup, 32 concurrent writers over 3 rounds, and **treats failure as fatal**.
Readiness never opens.

Reproduce it in isolation, which reports which phase failed and why:

```sh
buzzctl preflight <env>
```

| Symptom | Cause | Action |
|---|---|---|
| Credentials rejected | MinIO user missing or rotated | Re-run the init job: `kubectl -n buzz delete job buzz-minio-init` then `helm upgrade` |
| More than one writer won | The store ignores preconditions | The backend is not usable. If it is GCS, see [ADR-001](90-adr/ADR-001-object-storage.md) — this is expected and unfixable |
| Every writer refused | MinIO is degraded, no write quorum | `kubectl -n buzz get pods -l app.kubernetes.io/component=object-storage` |
| Bucket does not exist | Init job never ran or failed | `kubectl -n buzz logs job/buzz-minio-init` |

**Never set `BUZZ_GIT_CONFORMANCE_PROBE=false` to get past this.** The probe is
not the problem; it is reporting one. Disabling it converts a startup failure
into silent data loss on concurrent git pushes.

### Cloud SQL proxy failure

```sh
kubectl -n buzz logs deploy/buzz -c cloud-sql-proxy --tail=50
```

- *permission denied* → the Workload Identity binding. The relay's KSA must be
  bound to the relay GSA, and that GSA needs `roles/cloudsql.client`. Confirm:
  ```sh
  kubectl -n buzz get sa buzz-relay -o jsonpath='{.metadata.annotations}'
  gcloud iam service-accounts get-iam-policy <relay-gsa>
  ```
- *connection refused* → check the instance is up and Private Service Access
  peering exists.
- Pod stuck in `Init` forever → the cluster is below 1.29 and is treating the
  sidecar as a blocking init container. See
  [ADR-002](90-adr/ADR-002-cloudsql-native-sidecar.md).

### Redis TLS failure

Certificate errors mentioning `rediss` mean the Memorystore CA is missing or
wrong:

```sh
kubectl -n buzz get configmap buzz-redis-ca -o yaml
```

Re-fetch with `buzzctl secrets init <env>` and redeploy. If it cannot be made to
work, the documented fallback is `redis_transit_encryption = false` — a real
posture reduction, recorded in [ADR-005](90-adr/ADR-005-memorystore-tls.md).

### Refused at admission

```sh
kubectl -n buzz get events --field-selector reason=FailedCreate
```

`denied by attestor` means Binary Authorization has no attestation for the
digest. Either attest it:

```sh
export BUZZ_ATTESTOR_KEY_VERSION=projects/.../cryptoKeyVersions/1
buzzctl images mirror <env>
```

or, for a non-production environment, set `enable_binary_authorization = false`
and re-apply. This looks like a registry problem in the pod events and is not.

---

## Upgrading Buzz

```sh
buzzctl images mirror <env> --version 0.5.24
buzzctl preflight <env>
buzzctl deploy <env>
buzzctl verify <env>
```

Read the upstream `CHANGELOG.md` first, particularly for database migrations —
the relay runs them at startup (`BUZZ_AUTO_MIGRATE=true`), so the first pod of a
new version applies them.

Deploy is `--atomic`: a failed rollout rolls back. Rolling back a *migration* is
not automatic — if a release migrates the schema and then fails, restore from the
Cloud SQL PITR window rather than deploying the old image against a new schema.

Always promote dev → staging → prod. Staging exists to run the migration once
before production does.

---

## Upgrading the cluster

The release channel handles control-plane upgrades in the maintenance window.
Node pools auto-upgrade with `max_surge: 1, max_unavailable: 0`.

Before a manual upgrade, check MinIO can lose a node: it has
`maxUnavailable: 1`, and a drain that evicts two servers at once from a 4-node
erasure set loses write availability.

```sh
kubectl -n buzz get pdb
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

---

## Scaling

**Relay** — HPA on CPU is enabled above dev. To change the envelope, edit
`buzz.autoscaling` in `values-<env>.yaml` and redeploy.

Watch the database pool when raising `maxReplicas`: Cloud SQL `max_connections`
must exceed replicas × writer pool size plus headroom for migrations and
`buzz-admin`. The `db_pool_acquire_timeouts` alert fires when it does not.

**MinIO** — not a knob. The erasure set is sized at first start, so growing it
means adding capacity deliberately: raise `minio.persistence.size` (PVC expansion,
if the storage class allows it), or plan a migration to a wider set. Do not
change `minio.replicas` from 4 to 5 and expect it to work; the chart's validation
refuses 2 and 3 outright for the same reason.

**Cloud SQL** — `postgres_tier` in the tfvars, then `infra apply`. A tier change
causes a brief failover on a regional instance.

---

## Rotating credentials

```sh
buzzctl rotate hmac <env>     # git hook HMAC; rolls the relay after
buzzctl rotate minio <env>    # relay object-store credentials
```

`rotate minio` has a window between the new credentials being written and the
relay picking them up, during which media uploads may fail. It prompts. The old
MinIO user is left in place; remove it once the rollout is confirmed.

**The relay private key cannot be rotated**, and `buzzctl` refuses with an
explanation. It is an identity, not a credential: every event the relay has
signed becomes unverifiable against a new key, and every NIP-42 session breaks.
A genuine compromise is a migration with a communications plan — new relay
identity, clients re-pinned, users told the workspace identity changed.

---

## Onboarding and offboarding

See [50-onboarding.md](50-onboarding-users-agents.md).

Urgent revocation, when "next authorised event" is not fast enough:

```sh
buzzctl offboard <env> --npub npub1...
kubectl -n buzz rollout restart deploy/buzz    # drops live sockets
```

---

## Certificates

```sh
gcloud certificate-manager certificates list --project <project>
```

Stuck in `PROVISIONING` → the DNS authorization record is missing. Get the
expected records:

```sh
terraform -chdir=terraform/environments/<env> output dns_authorization_records
```

An expiry alert 20 days out usually means the same thing: someone tidied the
authorization records out of the zone and renewal is now failing.

---

## Clients disconnecting every 30 seconds

The load-balancer backend timeout has reverted to its default. Confirm the
policy is attached:

```sh
kubectl -n buzz get gcpbackendpolicy buzz-backend -o yaml | grep timeoutSec
```

It should be 3600. Google's default of 30s severs idle WebSockets, and Buzz
clients hold connections for hours.

---

## `buzz_storage_sweep_ok` is 0

The hourly bucket sweep is failing. Media upload and download are unaffected;
usage metrics and the community-deletion control plane are not.

Almost always the relay's credentials lack **bucket-level** `s3:ListBucket`,
which is a separate grant from the object-level permissions media needs. The
MinIO init job applies the correct policy — re-run it:

```sh
kubectl -n buzz delete job buzz-minio-init
helm upgrade buzz helm/buzz-gke --reuse-values -n buzz
```

---

## Restoring

See [40-backup-dr.md](40-backup-dr.md).

---

## Reading the relay's telemetry

Metric families and their cardinality ceilings are documented in the upstream
chart's README. Two worth knowing:

- `buzz_readiness_dependency_checks_total{dependency,outcome}` — which dependency
  is holding readiness closed.
- `buzz_db_pool_acquire_attempts_total{pool_role,operation,outcome}` — pool
  pressure by operation. `outcome="timeout"` climbing means the pool or
  `max_connections` is too small.

**Do not add labels** in `monitoring.extraMetricRelabeling`. The ceilings assume
none; adding pod, version or tenant labels multiplies the series count and gets
the deployment throttled by GMP ingestion limits.
