# Quickstart

Standing up `dev` end to end. Allow about 45 minutes, most of it waiting for the
cluster and Cloud SQL.

Work through [prerequisites](01-prerequisites.md) first — particularly the owner
keypair, which blocks the deploy step.

## 1. Bootstrap the project (once)

```sh
./scripts/buzzctl bootstrap \
  --project my-buzz-project \
  --repo Yash-Kavaiya/buzz-agentic-workspace
```

Enables the APIs, creates the versioned Terraform state bucket, sets up keyless
CI authentication, and writes the bucket name into each environment's
`backend.tf`. It prints the `google-github-actions/auth` snippet for CI at the
end.

## 2. Fill in the environment

```sh
$EDITOR terraform/environments/dev/terraform.tfvars
```

At minimum: `project_id`, `domain`, `relay_hostname`, `admin_hostname`.

Then the owner identity:

```sh
./scripts/buzzctl keygen
$EDITOR config/dev.yaml       # ownerPubkey: <pubkey_hex from above>
```

Keep the secret half safe. It is the account that owns the workspace.

## 3. Build the infrastructure

```sh
./scripts/buzzctl infra init dev
./scripts/buzzctl infra plan dev      # read it
./scripts/buzzctl infra apply dev
```

15–25 minutes, mostly the cluster and Cloud SQL. It finishes by printing what is
still needed — the platform is up but nothing is serving yet.

If DNS is hosted outside this project, create the records now
([prerequisites](01-prerequisites.md#dns)). Certificates will sit in
`PROVISIONING` until the authorization records resolve.

## 4. Secrets

```sh
./scripts/buzzctl secrets init dev
```

Generates the relay identity, the git hook HMAC and the MinIO credentials, and
writes them to Secret Manager. It also caches the Memorystore CA locally, which
the relay needs to complete a `rediss://` handshake.

Safe to re-run: it never overwrites an existing version. Nothing secret is
printed.

## 5. Pin an image

```sh
./scripts/buzzctl images mirror dev
```

Copies `ghcr.io/block/buzz` into Artifact Registry, resolves the immutable
digest, and records it. The deploy uses the digest, never the tag.

## 6. Preflight

```sh
./scripts/buzzctl preflight dev
```

Five checks. The fifth is the one that matters: it proves the object store
honours `If-Match` and `If-None-Match` under 16 concurrent writers. On a first
install MinIO does not exist yet, so it reports that the probe will run as a
Helm hook instead — which is fine, and it runs for real in step 7.

## 7. Deploy

```sh
./scripts/buzzctl deploy dev
```

In order: renders values from Terraform output and `config/dev.yaml`, fetches
the upstream chart, installs, runs the conformance probe against the object
store once it is up, and waits for rollout.

`--atomic` is set, so a failed rollout rolls back rather than leaving the release
half-applied.

**Readiness is slower than a normal rollout.** The relay runs its own
object-store conformance probe at startup and does not open readiness until it
passes.

## 8. Verify

```sh
./scripts/buzzctl verify dev
```

Six checks — pods, MinIO, the NIP-11 relay document over HTTPS, a real WebSocket
handshake with a NIP-42 AUTH challenge, a metrics scrape, and the membership
store through `buzz-admin`.

The WebSocket check is the interesting one: a relay that upgrades but never
challenges means authentication is off, which the check reports as a finding
rather than a pass.

## 9. Add yourself

```sh
./scripts/buzzctl onboard user dev --npub npub1...
```

Then point a Buzz desktop client at `wss://buzz-dev.<domain>` and post
something.

To confirm the access control actually works:

```sh
./scripts/buzzctl offboard dev --npub npub1...
```

and watch the connection be refused.

## Promoting

Staging and production are the same commands with a different argument:

```sh
./scripts/buzzctl infra apply staging
./scripts/buzzctl secrets init staging
./scripts/buzzctl images mirror staging
./scripts/buzzctl preflight staging
./scripts/buzzctl deploy staging
./scripts/buzzctl verify staging
```

Two things differ above dev, and both need a decision rather than a default:

- **Binary Authorization is on.** Set `BUZZ_ATTESTOR_KEY_VERSION` to a Cloud KMS
  key version before `images mirror`, or the relay is refused at admission.
- **Production prompts.** `deploy` and `infra apply` against `prod` ask you to
  type the environment name. `BUZZCTL_ASSUME_YES=1` skips it for a reviewed
  pipeline; do not put it in your shell profile.

Before promoting, confirm the Redis handshake in the preflight output — see
[ADR-005](90-adr/ADR-005-memorystore-tls.md).

## When something is wrong

```sh
./scripts/buzzctl doctor dev
```

Checks the failure modes this platform actually produces, in the order they
happen, and explains each rather than just reporting it. Start there;
[runbooks](30-runbooks.md) covers what to do next.
