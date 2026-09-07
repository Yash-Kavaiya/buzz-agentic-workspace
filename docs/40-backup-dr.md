# Backup and disaster recovery

## What is protected, and how

Three things fail independently, so three mechanisms protect them.

| Data | Mechanism | Cadence | Retention |
|---|---|---|---|
| Postgres — events, membership, search | Cloud SQL automated backups + PITR | continuous WAL, nightly backup | 30 backups, 7-day PITR window |
| Object store — media, git packs, manifests | `mc mirror` to a GCS bucket | nightly 02:00 | `dr_retention_days`, versioned |
| Cluster — manifests, PVC contents | Backup for GKE | nightly 03:30 | `dr_retention_days`, 7-day delete lock |

Memorystore is not backed up. It carries presence, typing and pubsub fanout —
losing it costs live state, not durable data.

## The constraint on restoring object storage

**The GCS DR bucket is a restore source, not a runnable backend.**

Buzz cannot serve from GCS. Its git manifest pointer is updated with an S3
conditional write (`If-Match`), and the GCS S3-compatible API supports ETag
preconditions on reads only. Repointing the relay at the DR bucket produces a
relay that starts, fails its own startup conformance probe, and never becomes
Ready.

**Restoring means restoring into MinIO.** See
[ADR-001](90-adr/ADR-001-object-storage.md).

## Why the backup job cannot delete its own backups

The mirror runs with `roles/storage.objectUser` — write and overwrite, never
delete — and `mc mirror` runs **without** `--remove`, so an object deleted from
the live store is not deleted from the DR copy. Combined with bucket versioning
and optional locked retention, an attacker holding the mirror job's credentials
cannot erase what it has already written.

`dr_bucket_retention_locked = true` makes retention irreversible. Nobody,
including a project owner, can shorten or remove it. That is the point, and it
is why the default is `false` — turn it on when you are certain of the period.

## Enabling the mirror

The mirror writes to GCS through its S3-compatible endpoint, which needs an HMAC
key rather than a token:

```sh
buzzctl backup enable <env>
```

Mints the key for the backup service account and stores it as a Kubernetes
Secret. The secret half cannot be retrieved after creation, so re-running
reports the existing key rather than silently minting a second one.

## Checking

```sh
buzzctl backup verify <env>
```

Reads the marker object the mirror writes at the end of each successful run,
reports its age, and counts objects. It warns past 48 hours.

```sh
buzzctl backup now <env>
```

Triggers a mirror immediately and follows it.

**A backup that has never been restored is a hypothesis.** `backup verify` says
the copy exists; it does not say it can be restored. Run the drill below on a
schedule you actually keep.

---

## Restoring

### Postgres — point in time

```sh
gcloud sql instances clone <instance> <instance>-restore \
  --point-in-time '2026-09-07T14:30:00Z' --project <project>
```

Clone, verify, then repoint. Do not restore over the live instance: a clone lets
you confirm the data before committing, and keeps a rollback.

Repointing means updating the Cloud SQL connection name in Terraform and
redeploying, so the Auth Proxy sidecar targets the restored instance.

The PITR window is `transaction_log_retention_days` (7 by default, 35 maximum).
Beyond it, only the nightly backups exist.

### Object store — from the DR bucket into MinIO

Restore into a *running* MinIO, not into GCS.

```sh
kubectl -n buzz run mc-restore --rm -it --restart=Never \
  --image=quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z -- sh

mc alias set dst http://buzz-minio.buzz.svc.cluster.local:9000 "$ACCESS" "$SECRET"
mc alias set src https://storage.googleapis.com "$HMAC_ACCESS" "$HMAC_SECRET"
mc mirror --overwrite src/<dr-bucket> dst/buzz-media
```

Then, before declaring it done:

```sh
buzzctl preflight <env>
```

The conformance probe must pass against the restored store. A restore that
leaves the bucket in a state the CAS protocol cannot use is not a restore.

### Cluster — from Backup for GKE

```sh
gcloud beta container backup-restore backups list \
  --backup-plan=<plan> --location=<region> --project=<project>

gcloud beta container backup-restore restores create <name> \
  --backup=<backup> --restore-plan=<plan> --location=<region>
```

This returns namespace manifests and PVC contents. It does **not** return Cloud
SQL or the DR bucket — those are separate restores, above.

### Secrets

Secret Manager keeps prior versions. If a rotation broke something:

```sh
gcloud secrets versions list buzz-prod-git-hook-hmac --project <project>
gcloud secrets versions access <n> --secret buzz-prod-git-hook-hmac
```

Add the old value back as a new version and let External Secrets re-sync
(`refreshInterval`, or annotate the ExternalSecret to force it).

**The relay private key is the exception that has no restore path if it is lost
outside Secret Manager.** It is the workspace's identity. This is why
`buzzctl secrets init` never overwrites an existing version.

---

## The drill

Quarterly, against a scratch environment. A drill that is never run is not a
plan.

1. `buzzctl infra apply dev` into a throwaway project, or reuse dev.
2. Clone production's Cloud SQL to a point in time; repoint dev at the clone.
3. Mirror production's DR bucket into dev's MinIO.
4. `buzzctl preflight dev` — the conformance probe must pass on the restored data.
5. `buzzctl deploy dev && buzzctl verify dev`.
6. Connect a client, read historical messages, `git clone` a repository that
   existed before the backup, and push to it.
7. Record how long the whole thing took.

Step 6 is the one that matters. Media and messages restoring is necessary;
**a git push succeeding against restored state** is what proves the manifest
pointers and pack objects came back coherently.

## Objectives

Set these against what the drill actually measures, not aspiration:

| | Target | Bound by |
|---|---|---|
| RPO — Postgres | ~seconds | Continuous WAL within the PITR window |
| RPO — object store | up to 24h | Nightly mirror. Shorten `minio.backup.schedule` if unacceptable |
| RTO — relay only | ~15 min | Redeploy against healthy dependencies |
| RTO — full region rebuild | hours | `infra apply` + Cloud SQL restore + object mirror-back |

The object-store RPO is the weak one. A day of media and git pushes is
recoverable from nothing but the live MinIO, which survives two node failures
but not a region loss. If that is unacceptable, raise the mirror frequency —
the cost is read load on the live store.
