#!/usr/bin/env bash
#
# Vendor the upstream Buzz chart into helm/buzz-gke/charts/.
#
# `helm dependency build` also works, and the original reason for replacing it
# turned out to be a misdiagnosis worth recording: `helm template` was failing
# with "found in Chart.yaml, but missing in charts/ directory: buzz" while the
# tarball was demonstrably on disk. The cause was `*.tgz` in .helmignore, which
# Helm applies when LOADING a chart directory, so it skipped the dependency it
# had just written. Not the downloader's fault at all.
#
# This script stays because the post-condition below — assert the artifact
# exists at the exact path Helm will look for — is what turned an opaque error
# into a locatable one. `helm dependency build` gives no such guarantee.
#
# The dependency's coordinates are read from Chart.yaml rather than repeated
# here, so bumping the upstream version stays a one-line change.

set -euo pipefail

CHART_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../helm/buzz-gke" && pwd)}"

command -v helm >/dev/null 2>&1 || {
  echo "helm is required" >&2
  exit 1
}

# Chart.yaml is small and well-formed; python is already a dependency of the
# other tooling, and this avoids a yq requirement.
read_dependencies() {
  python3 - "$CHART_DIR/Chart.yaml" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as handle:
    chart = yaml.safe_load(handle) or {}

for dependency in chart.get("dependencies") or []:
    name = dependency.get("name")
    version = dependency.get("version")
    repository = (dependency.get("repository") or "").rstrip("/")
    if not (name and version and repository):
        sys.exit(f"incomplete dependency entry: {dependency}")
    if not repository.startswith("oci://"):
        # A classic repo needs `helm repo add` first; this vendoring path only
        # claims to handle the OCI case the chart actually uses.
        sys.exit(f"{name}: only oci:// dependencies are vendored here, got {repository}")
    print(f"{name}\t{version}\t{repository}")
PY
}

mkdir -p "$CHART_DIR/charts"

while IFS=$'\t' read -r name version repository; do
  [[ -n "$name" ]] || continue
  target="$CHART_DIR/charts/${name}-${version}.tgz"

  if [[ -f "$target" ]]; then
    echo "already vendored: ${name}-${version}.tgz"
    continue
  fi

  # Remove other versions of the same chart, or helm sees two and refuses.
  rm -f "$CHART_DIR/charts/${name}-"*.tgz

  echo "pulling ${repository}/${name}:${version}"
  helm pull "${repository}/${name}" \
    --version "$version" \
    --destination "$CHART_DIR/charts"

  [[ -f "$target" ]] || {
    echo "helm pull reported success but $target does not exist" >&2
    ls -la "$CHART_DIR/charts" >&2
    exit 1
  }
  echo "vendored ${name}-${version}.tgz"
done < <(read_dependencies)
