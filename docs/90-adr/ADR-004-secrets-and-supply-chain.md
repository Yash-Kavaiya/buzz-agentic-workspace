# ADR-004: Where secrets live, and what may run

- **Status**: Accepted
- **Date**: 2026-09-07
- **Decision**: Secret Manager is the source of truth; External Secrets renders
  one Kubernetes Secret; the relay reads that Secret and has no Secret Manager
  access of its own. Images run only by digest, mirrored into Artifact Registry
  and gated by Binary Authorization.

## Context

The upstream chart takes a `secrets.existingSecret` and reads whatever keys it
finds. Something has to put that Secret in the cluster. And something has to
decide which image bytes are allowed to run.

## Decision

### Secrets

**Terraform manages the *containers*; it manages *versions* only where the value
is already in state.**

Terraform state lives in a GCS bucket that more people can read than should be
able to read the relay's identity key. So:

| Secret | Version written by | Why |
|---|---|---|
| `database-url`, `read-database-url`, `redis-url` | Terraform | Their components (the generated Cloud SQL password, the Memorystore AUTH string) are already in state. Writing them adds no new exposure. |
| `relay-private-key`, `git-hook-hmac`, `minio-*` | `buzzctl secrets init` | Generated through the API and never written to state or a plan file. |

The relay private key is the workspace's cryptographic identity. Anyone who can
read Terraform state should not thereby be able to impersonate the relay.

**The relay has no Secret Manager access.** Only the External Secrets Operator's
service account does, and its grants are per-secret rather than project-wide
(`terraform/modules/secrets`). A compromised relay cannot enumerate the
project's secrets; it can read the credentials already in its own pod, which it
needs anyway.

**`deletionPolicy: Retain`** on the ExternalSecret: if the ExternalSecret or the
store is removed, the relay keeps the credentials it has rather than losing its
database and object store mid-flight.

Optional keys (`READ_DATABASE_URL`, `BUZZ_KLIPY_API_KEY`) are listed separately,
because a secret with no version fails the whole ExternalSecret and would take
the relay's working credentials down with it.

### Supply chain

Buzz publishes to `ghcr.io`. We do not run images from there.

`buzzctl images mirror` copies the tag into Artifact Registry, resolves the
immutable digest, and writes it into the environment's generated values. The
deploy is by digest. `buzzctl deploy` refuses to run without one — a tag can be
moved to different bytes, a digest cannot.

Binary Authorization enforces this at admission: an image without an attestation
from the configured attestor is refused, with GKE's own system images
allowlisted. The AR repository has `immutable_tags` enabled as well, so a tag
cannot be repointed even within our own registry.

## Consequences

- **Binary Authorization needs a key before the first production deploy.**
  Without `BUZZ_ATTESTOR_KEY_VERSION`, `buzzctl images mirror` warns and creates
  no attestation, and the relay Pod is refused at admission. `dev` sets
  `enable_binary_authorization = false` so the first deploy is not blocked on key
  ceremony. This is the most likely first-run stumble; `buzzctl doctor`
  recognises the admission denial and says so, because it otherwise looks like a
  registry problem.
- **Rotating the relay private key is refused by `buzzctl rotate`**, with an
  explanation. It is an identity change, not a credential refresh: every event
  the relay has signed becomes unverifiable and every NIP-42 session breaks. If
  the key is genuinely compromised that is a migration with a communications
  plan.
- Rotating the git hook HMAC or the MinIO credentials is supported and rolls the
  relay afterwards, because replicas must agree on the HMAC to verify each
  other's git hook callbacks.
- Secret Manager replication is user-managed and pinned to the platform region,
  so payloads do not leave the jurisdiction the rest of the data lives in.
