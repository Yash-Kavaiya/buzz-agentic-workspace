# Policy

Machine-checkable versions of the decisions in `docs/90-adr`. A decision that
only exists in prose is a decision that regresses.

| File | Input | Run |
|---|---|---|
| `conftest/helm.rego` | rendered Kubernetes manifests | `conftest test --policy policy/conftest rendered/prod.yaml` |
| `conftest/terraform.rego` | `terraform show -json` plan | `conftest test --policy policy/conftest --namespace terraform plan.json` |
| `binauthz/policy.yaml` | reference copy of the enforced policy | applied by Terraform, not by hand |

Both are wired into `.github/workflows/`. `deny` fails the build; `warn` is
printed and does not.

## Choosing between deny and warn

`deny` is for things that are wrong in every environment: an unpinned image, a
literal secret, a public database IP, a service-account key.

`warn` is for things that are correct in one environment and not another: a
single relay replica, a zonal database, an open Cloud Armor allowlist. Those are
decisions, and CI should surface them rather than block dev.
