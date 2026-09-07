#!/usr/bin/env bash
#
# Every check that runs without a cloud account.
#
# These are not a substitute for `terraform validate` and `helm template`, which
# need their tools installed and which CI runs. They are what you can run on any
# machine, in seconds, before pushing.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=''; RED=''; DIM=''; BOLD=''; RESET=''
fi

failed=0
declare -a failures=()

run() {
  local name="$1"; shift
  printf '\n%s── %s %s\n' "$BOLD" "$name" "$RESET"
  if "$@"; then
    printf '%s   passed%s\n' "$GREEN" "$RESET"
  else
    printf '%s   FAILED%s\n' "$RED" "$RESET"
    failed=$((failed + 1))
    failures+=("$name")
  fi
}

missing_python_dep() {
  ! python3 -c "import $1" >/dev/null 2>&1
}

# ── Python-based checks ──────────────────────────────────────────────────────
if missing_python_dep yaml; then
  echo "PyYAML is required: pip install pyyaml" >&2
  exit 2
fi

run "key handling (known-answer vectors)" python3 tests/test_nostr_key.py
run "values rendering" python3 tests/test_render_values.py

if missing_python_dep botocore; then
  printf '\n%s── object-store conformance probe%s\n' "$BOLD" "$RESET"
  printf '%s   skipped: needs botocore (pip install boto3)%s\n' "$DIM" "$RESET"
else
  run "object-store conformance probe" python3 tests/test_storage_conformance.py
fi

run "helm template structure" python3 tests/lint_helm_templates.py
run "conftest policies" ./tests/test_policy.sh

if missing_python_dep hcl2; then
  printf '\n%s── terraform invariants%s\n' "$BOLD" "$RESET"
  printf '%s   skipped: needs python-hcl2 (pip install python-hcl2)%s\n' "$DIM" "$RESET"
else
  run "terraform invariants" python3 tests/lint_terraform.py
  run "terraform module wiring" python3 tests/lint_terraform_wiring.py
fi

# ── Shell ────────────────────────────────────────────────────────────────────
if command -v shellcheck >/dev/null 2>&1; then
  run "shellcheck" shellcheck -S warning -x scripts/buzzctl scripts/lib/*.sh tests/run_all.sh
else
  printf '\n%s── shellcheck%s\n' "$BOLD" "$RESET"
  printf '%s   skipped: shellcheck is not installed%s\n' "$DIM" "$RESET"
fi

# ── YAML ─────────────────────────────────────────────────────────────────────
if command -v yamllint >/dev/null 2>&1; then
  run "yamllint" yamllint -c .yamllint.yml \
    config/ helm/buzz-gke/values.yaml helm/buzz-gke/values-dev.yaml \
    helm/buzz-gke/values-staging.yaml helm/buzz-gke/values-prod.yaml \
    .github/workflows/ .github/ci-values.yaml
else
  printf '\n%s── yamllint%s\n' "$BOLD" "$RESET"
  printf '%s   skipped: yamllint is not installed%s\n' "$DIM" "$RESET"
fi

# ── The real tools, if they happen to be here ────────────────────────────────
if command -v terraform >/dev/null 2>&1; then
  for env in dev staging prod; do
    run "terraform validate ($env)" bash -c "
      terraform -chdir=terraform/environments/$env init -backend=false >/dev/null &&
      terraform -chdir=terraform/environments/$env validate"
  done
  run "terraform fmt" terraform fmt -check -recursive terraform/
elif command -v tofu >/dev/null 2>&1; then
  # OpenTofu shares hclwrite with Terraform, so `tofu fmt` produces byte-identical
  # output. `validate` still needs provider schemas and so is left to CI.
  run "tofu fmt (equivalent to terraform fmt)" tofu fmt -check -recursive terraform/
  printf '%s   note: validate needs provider schemas; CI runs terraform validate%s\n' "$DIM" "$RESET"
else
  printf '\n%s── terraform validate%s\n' "$BOLD" "$RESET"
  printf '%s   skipped: neither terraform nor tofu is installed. CI runs it.%s\n' "$DIM" "$RESET"
fi

if command -v helm >/dev/null 2>&1; then
  # Both, with the same three value layers CI uses. `lint` is what applies the
  # upstream chart's values.schema.json — `template` alone does not, so linting
  # here is what catches a value the subchart's schema rejects.
  run "helm lint + template" bash -c "
    ./scripts/lib/fetch-chart-deps.sh >/dev/null &&
    helm lint helm/buzz-gke \
      --values helm/buzz-gke/values.yaml \
      --values helm/buzz-gke/values-prod.yaml \
      --values .github/ci-values.yaml &&
    helm template buzz helm/buzz-gke --namespace buzz \
      --values helm/buzz-gke/values.yaml \
      --values helm/buzz-gke/values-prod.yaml \
      --values .github/ci-values.yaml >/dev/null"
else
  printf '\n%s── helm lint + template%s\n' "$BOLD" "$RESET"
  printf '%s   skipped: helm is not installed. CI runs it.%s\n' "$DIM" "$RESET"
fi

# ── Result ───────────────────────────────────────────────────────────────────
echo
if (( failed > 0 )); then
  printf '%s%d check(s) failed:%s %s\n' "$RED" "$failed" "$RESET" "${failures[*]}"
  exit 1
fi
printf '%sall checks passed%s\n' "$GREEN" "$RESET"
