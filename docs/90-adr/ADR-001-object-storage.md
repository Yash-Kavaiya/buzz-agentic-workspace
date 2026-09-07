# ADR-001: MinIO in-cluster, not Google Cloud Storage

- **Status**: Accepted
- **Date**: 2026-09-07
- **Decision**: Buzz's object store is a distributed MinIO StatefulSet running in
  the GKE cluster. Google Cloud Storage is used only as a disaster-recovery
  mirror target, never as a live backend.

## Context

Buzz needs S3-compatible object storage for two things: media attachments, and
the git repositories it hosts. On a Google Cloud platform, the obvious answer is
GCS through its S3-compatible XML API with HMAC interoperability keys. That is
the answer this decision rejects, and the reason is specific.

Buzz hosts git with **no persistent filesystem**. A repository's entire state is
a set of immutable, content-addressed pack objects plus a single mutable
*manifest pointer*. Concurrent pushes are serialised by exactly one primitive: a
conditional PUT of that pointer.

From `block/buzz`, `docs/git-on-object-storage.md` (§Push, step 7):

```
7. result := PUT M_R (value = d_after)          # CAS (A3)
       If-Match: e         if a pointer already exists (e from step 3)
       If-None-Match: *    if the repo has no pointer yet (first push / repo init)
```

and its axiom A3:

> **(A3) Linearizable conditional write (CAS).** `PUT M_R If-Match: e` succeeds
> and replaces the value iff the current ETag is exactly `e` [...] Among any set
> of conditional writes predicated on the same ETag, at most one succeeds.

The implementation is in `crates/buzz-relay/src/api/git/cas_publish.rs`
(`ParentState::if_match`) and `crates/buzz-relay/src/api/git/store.rs`.

### The constraint

**Google Cloud Storage supports ETag preconditions on read requests only.**
Write preconditions use generation numbers (`x-goog-if-generation-match`), which
are not `If-Match` and are not exposed through the S3-compatible surface an S3
client speaks. Google's own documentation states that Cloud Storage supports
preconditions with ETags only for read requests in the JSON and XML APIs; the
same limitation is recorded independently in
[`apache/arrow-rs-object-store#325`](https://github.com/apache/arrow-rs/issues/7146),
where the object-store crate cannot implement conditional put against GCS for
this reason.

### Why this is fatal rather than degrading

The relay does not discover this at push time. It probes for it at **startup**,
and treats failure as fatal — `crates/buzz-relay/src/main.rs:562`:

```rust
// Git-on-object-storage: admit the configured S3/MinIO backend against the
// linearizable conditional-write axiom (A3) before serving git traffic.
// Failure is fatal: a backend that cannot satisfy pointer CAS invalidates
// the manifest-pointer protocol. This is a deployment gate, not a proof.
```

The probe runs 32 concurrent writers over 3 rounds by default. Against GCS it
fails, readiness never opens, and the operator sees a relay that starts cleanly
and then sits in `0/3 Ready` forever with a probe report in its logs that most
people have never seen before.

If the probe were disabled (`BUZZ_GIT_CONFORMANCE_PROBE=false`), the outcome is
worse, not better: concurrent pushes to the same repository would each believe
they won, and one would silently overwrite the other. Silent data loss in a git
host is not an acceptable trade for using a managed service.

## Decision

Run MinIO in the cluster: 4 servers × 1 drive, erasure-coded, on
`premium-rwo` (PD-SSD) volumes, with hard pod anti-affinity so no two servers
share a node.

MinIO is the backend upstream's own concurrency regression test is written
against — `docs/git-on-object-storage.md` records an 8-way live CAS race
(`e2e_git::git_concurrent_push_one_wins_and_repo_recovers`) passing against it,
plus a 16-way calibration run. It is the store with the most evidence behind it.

GCS still earns its place, as a **DR mirror**: `mc mirror` copies the bucket
nightly into a versioned, optionally retention-locked GCS bucket
(`terraform/modules/backup`). Restores go back into MinIO. See
`docs/40-backup-dr.md`.

## Alternatives considered

**GCS with the conformance probe disabled, git unused.** Viable only if the
organisation commits to never using Buzz's git hosting. Media alone works fine
on GCS. Rejected because the constraint is invisible: nothing stops a user
creating a repository, and the failure is silent corruption rather than an
error. If the organisation later decides it genuinely will never use Buzz git,
this becomes reasonable — revisit this ADR rather than quietly flipping the flag.

**AWS S3 cross-cloud.** S3 has supported `If-Match` conditional writes since
2024 and would pass the probe. Rejected: cross-cloud egress costs on every media
read and git fetch, a second cloud's IAM to manage, and a network path outside
the VPC for the platform's bulk data.

**Rook/Ceph.** Conformant and self-hosted, but a substantially larger operational
surface than MinIO for the same requirement.

## Consequences

**Accepted costs:**

- MinIO is ours to operate — capacity planning, upgrades, drive failures, and
  rebalancing. `docs/30-runbooks.md` covers the routine cases.
- MinIO's community edition is **AGPL-3.0**. We run it as an unmodified network
  service and do not distribute it, which does not trigger the source-provision
  obligation for our own code. If the organisation's policy prohibits AGPL
  software outright, that is a blocker to raise now rather than at audit time.
- The `minio` node pool is fixed at 4 nodes and deliberately not autoscaled: the
  erasure set is sized at first start, so scaling is a migration, not a knob.

**Bought:**

- Data never leaves the VPC. Media and repositories are on disks the
  organisation controls, encrypted with CMEK.
- Git push safety rests on the primitive it was designed around, on the backend
  it was tested against.

## Enforcement

The decision is checkable, not just documented:

- `helm/buzz-gke/files/storage_conformance.py` reproduces all four probe phases
  and runs as a Helm `pre-install` hook and on demand via `buzzctl preflight`.
  Pointing this platform at GCS fails **before** anything is deployed, with a
  message naming the cause.
- `tests/test_storage_conformance.py` proves the probe itself works: it admits a
  conforming fake store and rejects a GCS-shaped one that ignores the
  precondition headers.
