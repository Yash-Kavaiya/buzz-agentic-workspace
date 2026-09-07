# Security model

Written to be handed to a security reviewer. It states what this platform
enforces, what it cannot enforce, and where the sharp edges are.

## Start here: Buzz has no SSO

**Buzz has no OIDC or SAML authentication for humans.** Identity is a Nostr
keypair — a secp256k1 secret held by the user, and the x-only public half as
their identifier. The relay authenticates connections with NIP-42 over
WebSocket and NIP-98 for the admin HTTP API, and authorises against its
`relay_members` table.

This is a property of Buzz, not a gap in this deployment. The only OIDC in the
upstream tree is in `buzz-agent`, for authenticating to LLM providers — not user
login.

What follows from that, concretely:

| Expectation | Reality here |
|---|---|
| Provisioning from the IdP | A pubkey is added to the relay roster by an operator running `buzzctl onboard user` |
| De-provisioning by disabling the IdP account | `buzzctl offboard` removes the pubkey. Disabling someone's Google account does **not** revoke their Buzz access |
| MFA enforced centrally | The user's key is the only factor. Its protection is the user's device |
| Session revocation | Removing a member takes effect on that connection's next authorised event, not instantly |
| "Who is this really?" | The binding from pubkey to person is whatever your onboarding process records. Buzz does not know |

**The offboarding gap is the item to raise with whoever owns joiner/mover/leaver
process.** Removal from Buzz has to be an explicit step in the leaver checklist,
because nothing else will do it.

Two mitigations are wired in and both are partial: Cloud Armor can restrict
source ranges to corporate egress, so a departed employee off the VPN cannot
reach the relay at all; and IAP on the admin console *is* tied to Google
identity, so operator access to moderation tooling is revoked with the Google
account even though relay membership is not.

## Defence in depth

Six layers. None is the whole boundary.

### 1. Network edge

Cloud Armor in front of the Gateway (`terraform/modules/edge`):

- **Source allowlist** — `allowed_source_ranges`, default `0.0.0.0/0`. Narrowing
  this to corporate egress is the single largest reduction in attack surface
  available, at the cost of remote access. It is a decision recorded in the
  tfvars, not a default to accept silently.
- **Geo denial** — optional, evaluated at higher priority than the allowlist.
- **OWASP preconfigured rules** — SQLi, XSS, LFI, RCE at sensitivity 1. The
  lowest sensitivity is deliberate: Buzz carries signed Nostr events and base64
  media in request bodies, and aggressive heuristics false-positive on that. A
  WAF that blocks real messages gets switched off entirely.
- **Per-IP rate-based ban** — throttles at the threshold, bans at 3×. Tuned high
  because a NAT'd office egresses from one address.

Cloud Armor counts HTTP requests, including the WebSocket upgrade. It does not
see messages on an established socket — that is the relay's job (layer 3).

### 2. Transport and platform

- No public node IPs; egress via Cloud NAT.
- No public control-plane endpoint, in any environment, by default.
- Cloud SQL and Memorystore on private IPs over Private Service Access; Cloud
  SQL has `ipv4_enabled = false` and the lint asserts it.
- TLS from Google-managed certificates, DNS-authorized so renewal does not
  depend on the data path being healthy.
- Workload Identity everywhere; `GKE_METADATA` mode blocks pods from reading the
  node's instance credentials.
- Dataplane V2 (eBPF), so NetworkPolicy is actually enforced. `buzzctl preflight`
  checks for the `anetd` DaemonSet, because NetworkPolicy objects are accepted by
  any cluster and silently do nothing without an enforcing datapath — which looks
  protected and is not.
- Default-deny NetworkPolicy in the namespace, with named exceptions and
  `169.254.169.254/32` excluded from egress.
- Shielded nodes, secure boot, integrity monitoring; CMEK application-layer
  encryption of Secrets in etcd.
- **A public control-plane endpoint with no authorized networks is refused.**
  The two settings are individually reasonable and catastrophic together — the
  Kubernetes API server on the open internet — so the `gke` module rejects the
  combination at plan time, and `policy/conftest/terraform.rego` and
  `tests/lint_terraform.py` assert it independently. A Trivy scan cannot see
  through the module's dynamic block, which is why the check is duplicated
  where the real values are visible.

### 3. Relay authorisation

The layer that actually decides who is in the workspace:

| Setting | Value | Effect |
|---|---|---|
| `BUZZ_REQUIRE_AUTH_TOKEN` | `true` | Clients must complete NIP-42 before doing anything |
| `BUZZ_REQUIRE_RELAY_MEMBERSHIP` | `true` | The authenticated pubkey must be on the roster |
| `BUZZ_PUBKEY_ALLOWLIST` | `true` | Closed by default: unknown keys are refused |
| `RELAY_OWNER_PUBKEY` | `config/<env>.yaml` | Workspace owner |
| `RELAY_OPERATOR_PUBKEYS` | `config/<env>.yaml` | Moderation rights on the admin console |

`RELAY_OPERATOR_PUBKEYS` overrides the owner fallback entirely, so
`render_values.py` always includes the owner in the list — otherwise setting a
single operator silently locks the owner out of their own console.

Rate limits are per-identity and split by actor class, so a misbehaving agent
cannot consume a human's budget: `BUZZ_RATE_LIMIT_HUMAN_*`,
`..._AGENT_STANDARD_*`, `..._AGENT_ELEVATED_*`, `..._AGENT_PLATFORM_*`, all set
from `config/<env>.yaml`.

### 4. Secrets

Detailed in [ADR-004](90-adr/ADR-004-secrets-and-supply-chain.md). The two
properties worth stating here:

- **The relay cannot read Secret Manager.** Only the External Secrets Operator
  can, with per-secret grants rather than a project-wide role. A compromised
  relay reads the credentials already in its own pod and nothing more.
- **The relay's identity key never enters Terraform state.** Terraform creates
  the secret container; `buzzctl secrets init` writes the version through the
  API. State lives in a bucket more people can read than should be able to
  impersonate the relay.

### 5. Supply chain

- Images mirrored into Artifact Registry and deployed **by digest**.
  `buzzctl deploy` refuses to run without a pinned digest.
- `immutable_tags` on the repository: a tag cannot be repointed even internally.
- Binary Authorization enforcing, with GKE's own system images allowlisted. An
  unattested image is refused at admission.
- CMEK on image layers.

### 6. Audit

- Buzz's own event log is append-only and cryptographically signed. Every
  message, reaction and workflow step carries its author's signature, human or
  agent alike.
- Cloud Audit Logs and GKE audit events export to BigQuery
  (`terraform/modules/observability`), retained per `audit_retention_days`.
- VPC flow logs at 50% sampling.
- Load balancer logging at 50% sampling.
- Postgres logs connections, disconnections, lock waits, temporary files and
  statements slower than 1s. `log_parameter_max_length = 0` keeps bind
  parameter *values* out of those logs, so slow-query text is available for
  incident triage without message content following it into Cloud Logging.

**Offboarding does not remove history**, and should not: the event log is a
signed chain, and deleting entries would break the audit property that makes it
worth having.

## Agent identity

Agents are first-class members with their own keypairs, subject to the same
membership and rate-limit checks as people. The platform holds an agent's key
because an agent is a process we run:

```sh
buzzctl onboard agent prod --name deploy-bot
```

mints a keypair, stores it in a dedicated Secret Manager secret, and adds the
pubkey to the roster. The key is never printed.

Give the agent's workload a service account with `secretAccessor` on **that one
secret**, not on the project. The relay's own service account deliberately has no
Secret Manager access at all, and an agent should be no more privileged.

Human keys are different: they are generated on the human's own device and never
transit this tooling. `buzzctl` refuses an `nsec` outright, with an explanation,
so pasting a private key where a public one belongs fails loudly.

## Trust boundaries

| Boundary | Crossed by | Enforced by |
|---|---|---|
| Internet → platform | HTTPS/WSS to two hostnames | Cloud Armor, TLS, then NIP-42 + membership |
| Operator → admin console | HTTPS to the admin host | IAP (Google identity) **and** NIP-98 operator pubkeys |
| Relay pod → Cloud SQL | Auth Proxy on loopback | Workload Identity + IAM; mTLS to the instance |
| Relay pod → Secret Manager | *not permitted* | No IAM grant exists |
| ESO → Secret Manager | Workload Identity | Per-secret `secretAccessor` |
| Backup job → GCS DR | HMAC over HTTPS | `objectUser` — write and overwrite, **never delete** |
| CI → GCP | GitHub OIDC | Workload Identity Federation, repo- and ref-pinned. No service-account keys exist |

The backup grant is deliberate: a compromised cluster must not be able to erase
the backups it produces. Combined with bucket versioning and optional locked
retention, the DR copy survives an attacker holding the mirror job's credentials.

## Known limitations

Stated plainly, because a reviewer will find them anyway.

1. **No SSO, and no central session revocation.** Covered above. The largest gap,
   and inherent to Buzz.
2. **Membership removal is not instant.** It takes effect on the connection's
   next authorised event. For an urgent revocation, remove the member *and*
   restart the relay to drop live sockets.
3. **`allowed_source_ranges` defaults to open.** Correct for a distributed
   workforce, and a real exposure. Decide it explicitly.
4. **MinIO is ours to operate**, and is AGPL-3.0. See
   [ADR-001](90-adr/ADR-001-object-storage.md).
5. **Memorystore TLS is not yet verified against a live instance.** The trust
   chain is reasoned, not observed. `buzzctl preflight` must confirm it before
   promotion; the fallback is AUTH-only on a private VPC. See
   [ADR-005](90-adr/ADR-005-memorystore-tls.md).
6. **Egress is permissive by default.** `networkPolicy.allowedEgressCidrs` is
   `0.0.0.0/0` minus the metadata endpoint, because agents call LLM APIs and an
   over-tight policy fails as "agents mysteriously stop responding". Narrow it
   once the agent workloads in use are known.
7. **IAP cannot protect the relay.** Buzz clients carry no Google session
   cookie; an IAP-protected relay rejects every legitimate client. The relay's
   own authentication is the control there.
8. **The Cloud SQL DSN uses `sslmode=disable`.** This is correct — the Auth Proxy
   provides the mutually authenticated tunnel and the plaintext hop is inside the
   pod's network namespace — but it looks wrong in a scan report and will be
   asked about.

## Verifying the claims

Most of this is checkable rather than asserted:

```sh
python3 tests/lint_terraform.py          # private nodes, no public DB IP, Redis AUTH,
                                         # Workload Identity, CMEK, Dataplane V2
python3 tests/test_storage_conformance.py # the object-store gate detects a bad store
python3 tests/test_nostr_key.py          # key handling, incl. refusing an nsec
./scripts/buzzctl preflight <env>        # NetworkPolicy enforcement, secrets, storage
./scripts/buzzctl verify <env>           # NIP-42 challenge is actually issued
conftest test rendered/                  # digest pinning, no eval services in prod
```
