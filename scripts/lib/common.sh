#!/usr/bin/env bash
# Shared helpers for buzzctl. Sourced, never executed.
#
# Everything here is written to be safe under `set -euo pipefail`, which
# buzzctl sets: functions return status rather than exiting where the caller
# might reasonably want to handle a failure.

# ── Output ───────────────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_DIM=$'\033[2m'
  readonly C_RED=$'\033[31m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_BLUE=$'\033[34m'
  readonly C_BOLD=$'\033[1m'
else
  readonly C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD=''
fi

log()   { printf '%s\n' "$*" >&2; }
info()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
step()  { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }

die() {
  printf '%serror%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

# ── Repository layout ────────────────────────────────────────────────────────
# These are consumed by buzzctl, which sources this file; shellcheck cannot see
# across that boundary.
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
# shellcheck disable=SC2034
readonly TF_ENV_DIR="$REPO_ROOT/terraform/environments"
# shellcheck disable=SC2034
readonly TF_BOOTSTRAP_DIR="$REPO_ROOT/terraform/bootstrap"
# shellcheck disable=SC2034
readonly CHART_DIR="$REPO_ROOT/helm/buzz-gke"
# shellcheck disable=SC2034
readonly CONFIG_DIR="$REPO_ROOT/config"
# shellcheck disable=SC2034
readonly STATE_DIR="$REPO_ROOT/.buzzctl"

# ── Preconditions ────────────────────────────────────────────────────────────
require_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    die "missing required command(s): ${missing[*]}
Install them and re-run. See docs/01-prerequisites.md."
  fi
}

valid_env() {
  local env="${1:-}"
  case "$env" in
    dev|staging|prod) return 0 ;;
    *) return 1 ;;
  esac
}

require_env_arg() {
  local env="${1:-}"
  [[ -n "$env" ]] || die "an environment is required: dev, staging or prod"
  valid_env "$env" || die "unknown environment '$env' (expected dev, staging or prod)"
  [[ -d "$TF_ENV_DIR/$env" ]] || die "no Terraform root at $TF_ENV_DIR/$env"
  printf '%s' "$env"
}

env_state_dir() {
  local env="$1"
  local dir="$STATE_DIR/$env"
  mkdir -p "$dir"
  chmod 700 "$STATE_DIR" "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

# Production changes get a deliberate pause. Not a security control — a
# reflex-breaker, for the difference between `buzzctl deploy staging` and
# `buzzctl deploy prod` being four characters.
confirm_production() {
  local env="$1" action="$2"
  [[ "$env" == "prod" ]] || return 0
  [[ "${BUZZCTL_ASSUME_YES:-}" == "1" ]] && return 0

  if [[ ! -t 0 ]]; then
    die "refusing to $action production non-interactively.
Set BUZZCTL_ASSUME_YES=1 if this is a reviewed, automated pipeline."
  fi

  printf '%sAbout to %s PRODUCTION.%s Type the environment name to continue: ' \
    "$C_YELLOW" "$action" "$C_RESET" >&2
  local answer
  read -r answer
  [[ "$answer" == "prod" ]] || die "aborted"
}

# ── Terraform ────────────────────────────────────────────────────────────────
tf() {
  local env="$1"; shift
  terraform -chdir="$TF_ENV_DIR/$env" "$@"
}

# Reads the platform output and caches it. Callers get a path, not JSON on
# stdout, so a large output never has to round-trip through a shell variable.
platform_json() {
  local env="$1"
  local refresh="${2:-}"
  local state_dir cache
  state_dir="$(env_state_dir "$env")"
  cache="$state_dir/platform.json"

  if [[ -n "$refresh" || ! -f "$cache" ]]; then
    tf "$env" output -json platform > "$cache.tmp" 2>/dev/null \
      || die "could not read Terraform output for '$env'.
Has the infrastructure been applied?  buzzctl infra apply $env"
    if [[ ! -s "$cache.tmp" ]] || ! jq -e . "$cache.tmp" >/dev/null 2>&1; then
      rm -f "$cache.tmp"
      die "Terraform produced no usable 'platform' output for '$env'."
    fi
    mv "$cache.tmp" "$cache"
    chmod 600 "$cache"
  fi
  printf '%s' "$cache"
}

platform_get() {
  local env="$1" path="$2" cache
  cache="$(platform_json "$env")"
  jq -re "$path" "$cache" 2>/dev/null || die "platform output has no value at $path"
}

# ── Kubernetes ───────────────────────────────────────────────────────────────
ensure_kubecontext() {
  local env="$1" cluster region project
  cluster="$(platform_get "$env" '.cluster.name')"
  region="$(platform_get "$env" '.region')"
  project="$(platform_get "$env" '.project_id')"

  local context="gke_${project}_${region}_${cluster}"
  if ! kubectl config get-contexts "$context" >/dev/null 2>&1; then
    info "fetching cluster credentials for $cluster"
    gcloud container clusters get-credentials "$cluster" \
      --region "$region" --project "$project" >/dev/null \
      || die "could not get credentials for $cluster.
If the control plane is private, connect through a bastion, Cloud VPN or the
GKE Connect gateway first."
  fi
  kubectl config use-context "$context" >/dev/null
  printf '%s' "$context"
}

kube() {
  local env="$1"; shift
  local namespace
  namespace="$(platform_get "$env" '.namespace')"
  kubectl --namespace "$namespace" "$@"
}

# Name of the relay Deployment. Mirrors the upstream chart's fullname helper,
# which prefixes with the release name alone when it already contains "buzz".
relay_workload() {
  local release="$1"
  if [[ "$release" == *buzz* ]]; then
    printf '%s' "$release"
  else
    printf '%s-buzz' "$release"
  fi
}

# Runs buzz-admin inside a live relay pod. That pod already has the Cloud SQL
# Auth Proxy sidecar and the database credentials, so this is the only place
# membership changes can be made without minting a second set of credentials.
relay_exec() {
  local env="$1"; shift
  local release pod
  release="$(platform_get "$env" '.release')"

  pod="$(kube "$env" get pods \
    -l "app.kubernetes.io/instance=$release,app.kubernetes.io/name=buzz" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || true

  [[ -n "$pod" ]] || die "no running relay pod found for release '$release'.
  kubectl -n $(platform_get "$env" '.namespace') get pods"

  kube "$env" exec "$pod" -c relay -- "$@"
}

# ── Secret Manager ───────────────────────────────────────────────────────────
secret_name() {
  local env="$1" suffix="$2" prefix
  prefix="$(platform_get "$env" '.name_prefix')"
  printf '%s-%s' "$prefix" "$suffix"
}

secret_has_version() {
  local env="$1" suffix="$2" project name
  project="$(platform_get "$env" '.project_id')"
  name="$(secret_name "$env" "$suffix")"
  gcloud secrets versions list "$name" --project "$project" \
    --filter='state:ENABLED' --format='value(name)' --limit=1 2>/dev/null | grep -q .
}

# Values are piped, never passed as arguments: a command line is visible in the
# process table to every other process on the machine.
secret_put() {
  local env="$1" suffix="$2" project name
  project="$(platform_get "$env" '.project_id')"
  name="$(secret_name "$env" "$suffix")"
  gcloud secrets versions add "$name" --project "$project" --data-file=- >/dev/null \
    || die "could not add a version to secret $name"
}

secret_get() {
  local env="$1" suffix="$2" project name
  project="$(platform_get "$env" '.project_id')"
  name="$(secret_name "$env" "$suffix")"
  gcloud secrets versions access latest --secret "$name" --project "$project" 2>/dev/null
}

# ── Nostr keys ───────────────────────────────────────────────────────────────
# Accepts either form and always yields the 64-char hex the relay stores.
# bech32 decoding is done in Python because it needs a real checksum check;
# a silently mistyped npub would add the wrong person to the roster.
normalize_pubkey() {
  local input="$1"
  python3 "$REPO_ROOT/scripts/lib/nostr_key.py" --decode "$input"
}

# ── Misc ─────────────────────────────────────────────────────────────────────
timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

confirm() {
  local prompt="$1"
  [[ "${BUZZCTL_ASSUME_YES:-}" == "1" ]] && return 0
  [[ -t 0 ]] || return 1
  printf '%s [y/N] ' "$prompt" >&2
  local answer
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}
