# ADR-002: Cloud SQL Auth Proxy as a native sidecar

- **Status**: Accepted
- **Date**: 2026-09-07
- **Decision**: The relay reaches Cloud SQL through a `cloud-sql-proxy` container
  declared in the upstream chart's `extraInitContainers` with
  `restartPolicy: Always`. No chart fork.

## Context

Cloud SQL is private-IP only (ADR-003). Three ways to reach it:

1. **Direct private IP.** Simplest. Requires a database password in the DSN and
   gives `sslmode=require` at best — encrypted, but not mutually authenticated.
2. **Auth Proxy as a sidecar.** Mutual TLS to the instance, IAM-based
   authorisation, and with `--auto-iam-authn` no database password exists at all.
3. **Auth Proxy as a separate Deployment.** A shared network hop, a single point
   of failure, and connection attribution lost.

Option 2 is the right answer, but the upstream chart exposes only
`extraInitContainers` — not `extraContainers`. An ordinary init container is
useless here: it must exit before the app starts, and a proxy never exits.

## Decision

Kubernetes 1.29 promoted **sidecar containers**: an init container with
`restartPolicy: Always` starts before the app container, keeps running for the
pod's lifetime, and is torn down after the app exits. That is exactly a sidecar,
declared in the init list.

Upstream renders `extraInitContainers` verbatim through `toYaml`, so the field
passes straight through. The extension point is sufficient as it stands; we do
not fork the chart.

Rendered by `scripts/lib/render_values.py` (`cloud_sql_sidecar`):

```yaml
extraInitContainers:
  - name: cloud-sql-proxy
    image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1
    restartPolicy: Always          # <- the field that makes it a sidecar
    args:
      - --structured-logs
      - --address=127.0.0.1        # loopback only
      - --port=5432
      - --http-address=0.0.0.0
      - --http-port=9801
      - --health-check
      - --exit-zero-on-sigterm
      - <project:region:instance>
```

`DATABASE_URL` then targets `127.0.0.1:5432` with `sslmode=disable`. That looks
alarming and is correct: the proxy establishes the mutually authenticated TLS
tunnel, and the plaintext hop is inside the pod's own network namespace. Setting
`sslmode=require` would make the relay try to negotiate TLS with the proxy's
local listener, which does not speak it.

`terraform/modules/gke/variables.tf` pins `min_master_version` at 1.31 with a
comment recording that 1.29 is the floor for this to work.

## Consequences

- **`min_master_version` is load-bearing.** Below 1.29, `restartPolicy` on an
  init container is ignored and the pod hangs at init forever. The comment on
  that variable exists so nobody lowers it casually.
- **The pre-upgrade migration Job is disabled.** `migrate.preUpgradeJob` cannot
  carry a sidecar, so it has no route to the database. `migrate.autoMigrate`
  stays on and the relay runs migrations at startup.
- **`buzz-admin` runs via `kubectl exec` into a relay pod**, which already has
  the proxy and the credentials. `buzzctl`'s `relay_exec` helper does this, and
  it is why membership changes need no second credential path.
- **`--auto-iam-authn` is off by default.** The passwordless IAM DSN needs
  validating against sqlx in dev before promotion (`gcp.cloudsql.autoIamAuthn`).
  Until then the built-in role's password from Secret Manager is the tested path;
  both are wired, and Terraform registers the relay GSA as a Cloud SQL IAM user
  either way.
- Proxy failures are diagnosable as themselves: it has its own health endpoints
  on 9801, and `buzzctl doctor` reads its container logs separately from the
  relay's, so "cannot reach the database" and "the proxy cannot authenticate"
  are distinguishable.
