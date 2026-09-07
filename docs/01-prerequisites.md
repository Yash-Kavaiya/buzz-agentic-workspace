# Prerequisites

## Tools

| Tool | Version | Needed for |
|---|---|---|
| `terraform` | ≥ 1.6 | everything under `terraform/` |
| `gcloud` | recent | authentication, Secret Manager, Artifact Registry |
| `kubectl` | ≥ 1.29 client | `buzzctl` day-2 commands |
| `helm` | ≥ 3.14 | `buzzctl deploy` (OCI chart support) |
| `jq` | any | `buzzctl` reads Terraform output with it |
| `python3` | ≥ 3.9 | value rendering, key handling, probes |
| `crane` *or* `docker` | any | `buzzctl images mirror` |

`buzzctl` checks for what each command needs and names anything missing. Python
needs `PyYAML`; nothing else — key generation is implemented against the standard
library on purpose, so an operator's machine needs no crypto package.

## Google Cloud

**A project**, with billing enabled, and an identity holding at minimum:

```
roles/owner                        # simplest for bootstrap
```

or, if you would rather not:

```
roles/resourcemanager.projectIamAdmin
roles/serviceusage.serviceUsageAdmin
roles/compute.networkAdmin
roles/container.admin
roles/cloudsql.admin
roles/redis.admin
roles/cloudkms.admin
roles/secretmanager.admin
roles/artifactregistry.admin
roles/iam.serviceAccountAdmin
roles/storage.admin
roles/dns.admin                    # if this project hosts the DNS zone
roles/monitoring.admin
roles/logging.admin
```

`terraform/bootstrap` enables the required APIs. If a landing-zone pipeline
already owns API enablement, set `enable_apis = false`.

**Quota** worth checking before the first apply, since these are the ones that
bite: regional in-use IP addresses, CPUs in the target region, PD-SSD capacity
(the `minio` pool alone requests 4 × `disk_size_gb`), and Cloud SQL instances.

## Networking

Pick CIDRs that do not overlap each other or anything the organisation may later
peer with. The defaults in the tfvars are already non-overlapping across the
three environments:

| | dev | staging | prod |
|---|---|---|---|
| nodes | `10.10.0.0/20` | `10.11.0.0/20` | `10.12.0.0/20` |
| pods | `10.20.0.0/16` | `10.21.0.0/16` | `10.22.0.0/16` |
| services | `10.30.0.0/20` | `10.31.0.0/20` | `10.32.0.0/20` |
| control plane | `172.16.0.0/28` | `172.16.0.16/28` | `172.16.0.32/28` |

**The pod range cannot be changed after the cluster is created.** A `/16`
supports roughly 256 nodes at the default 110 pods per node. Size it for the
cluster's lifetime.

## DNS

Two hostnames per environment:

```
buzz.<domain>          the relay        — clients connect here
buzz-admin.<domain>    the admin console — behind IAP
```

If Cloud DNS hosts the zone in this project, set `dns_zone_name` and Terraform
manages the records, including the certificate DNS authorizations.

If DNS lives elsewhere, leave `dns_zone_name = ""` and create four records by
hand after the first apply:

```
terraform -chdir=terraform/environments/prod output dns_authorization_records
terraform -chdir=terraform/environments/prod output -json platform | jq -r .edge.gateway_ip_address
```

Two `A` records pointing at the Gateway IP, and the two `CNAME` authorization
records. **Certificates will not issue without the authorization records, and
will not renew if they are later pruned** — a failure that surfaces 90 days
after someone tidies the zone.

## Cluster access

The control plane has no public endpoint by default, in any environment. Before
running `buzzctl` commands that talk to Kubernetes, have one of:

- a bastion VM inside the VPC,
- Cloud VPN or Interconnect to the VPC,
- the GKE Connect gateway.

For dev, `enable_public_control_plane = true` **together with**
`master_authorized_networks` set to your egress range works from a laptop. The
module refuses a public endpoint with an empty allowlist — that combination puts
the Kubernetes API server on the open internet.

## Identity, before the first deploy

`buzz.ownerPubkey` must be set in `config/<env>.yaml` before deploying. With
relay membership required — the default — **a relay with no owner is a relay
nobody can join**.

```
./scripts/buzzctl keygen
```

Keep the secret half in a password manager or hardware token. Put the public
half (`pubkey_hex`) in `config/<env>.yaml`. Changing it later changes who owns
the workspace.

## Optional, but decide before production

- **A Cloud KMS key version for Binary Authorization attestations.** Without it,
  `buzzctl images mirror` creates no attestation and the relay is refused at
  admission. `dev` ships with Binary Authorization off so the first deploy is
  not blocked on key ceremony; staging and prod have it on.
- **A Monitoring notification channel.** Alert policies without a channel are
  alerts nobody sees. Set `notification_channels` in the tfvars.
- **An IAP OAuth client** for the admin console, as a Kubernetes Secret named
  `buzz-iap-oauth` with `client_id` and `client_secret`. `buzzctl` does not mint
  OAuth clients.
- **A group for `iap_members`**, e.g. `group:buzz-operators@example.com`.

## Cost, roughly

Order of magnitude per month, `us-central1`, before committed-use discounts:

| | dev | prod |
|---|---|---|
| GKE nodes | ~3 × e2-standard-2/4 | ~2 × n2-standard-8 + 4 × n2-standard-8 |
| Cloud SQL | zonal 2 vCPU | regional HA 8 vCPU + replica |
| Memorystore | 1 GiB basic | 5 GiB standard HA |
| MinIO disks | 100 GiB balanced | 4 × 1 TiB PD-SSD |
| Edge | LB + Armor + certs | same |

Prod is dominated by the MinIO PD-SSD capacity and the regional Cloud SQL pair.
Size `minio.persistence.size` against expected media and repository volume
rather than accepting the 1 TiB default.
