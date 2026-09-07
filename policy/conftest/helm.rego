# Policy checks over rendered Kubernetes manifests.
#
#   helm template buzz helm/buzz-gke -f helm/buzz-gke/values.yaml \
#     -f helm/buzz-gke/values-prod.yaml -f .buzzctl/prod/values.generated.yaml \
#     > rendered/prod.yaml
#   conftest test --policy policy/conftest rendered/prod.yaml
#
# These encode the decisions in docs/90-adr as machine-checkable rules, so a
# regression is caught in CI rather than in an incident.

package main

import rego.v1

# ── Images must be pinned by digest ──────────────────────────────────────────
# A tag can be moved to different bytes; a digest cannot. Binary Authorization
# also attests digests, so a tag deploy is unattestable by construction.

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}

pod_spec(obj) := obj.spec.template.spec if {
	obj.kind in {"Deployment", "StatefulSet", "DaemonSet", "Job"}
}

pod_spec(obj) := obj.spec.jobTemplate.spec.template.spec if {
	obj.kind == "CronJob"
}

all_containers(obj) := containers if {
	spec := pod_spec(obj)
	containers := array.concat(
		object.get(spec, "containers", []),
		object.get(spec, "initContainers", []),
	)
}

deny contains msg if {
	input.kind == "Deployment"
	input.metadata.labels["app.kubernetes.io/name"] == "buzz"
	some container in all_containers(input)
	container.name == "relay"
	not contains(container.image, "@sha256:")
	msg := sprintf(
		"%s/%s: the relay image %q is not pinned by digest. Run `buzzctl images mirror`; a tag can be repointed to different bytes and cannot be attested.",
		[input.kind, input.metadata.name, container.image],
	)
}

# ── The relay's secrets must come from an existing Secret ────────────────────
# The upstream chart can autogenerate secrets, but only safely under
# `helm install`. Under `helm template` (ArgoCD, Flux, and our own CI render)
# `lookup` returns empty and every sync regenerates them.

deny contains msg if {
	input.kind == "Deployment"
	input.metadata.labels["app.kubernetes.io/name"] == "buzz"
	some container in all_containers(input)
	container.name == "relay"
	some env in container.env
	env.name == "BUZZ_RELAY_PRIVATE_KEY"
	not env.valueFrom.secretKeyRef
	msg := sprintf(
		"%s/%s: BUZZ_RELAY_PRIVATE_KEY must come from a secretKeyRef, never an inline value.",
		[input.kind, input.metadata.name],
	)
}

# ── No plaintext secrets anywhere in a pod spec ──────────────────────────────

secret_env_names := {
	"BUZZ_RELAY_PRIVATE_KEY",
	"BUZZ_GIT_HOOK_HMAC_SECRET",
	"BUZZ_S3_SECRET_KEY",
	"BUZZ_S3_ACCESS_KEY",
	"DATABASE_URL",
	"READ_DATABASE_URL",
	"REDIS_URL",
	"MINIO_ROOT_PASSWORD",
	"BUZZ_KLIPY_API_KEY",
}

deny contains msg if {
	input.kind in workload_kinds
	some container in all_containers(input)
	some env in container.env
	env.name in secret_env_names
	env.value
	env.value != ""
	msg := sprintf(
		"%s/%s container %q: %s has a literal value. Secrets belong in Secret Manager, rendered by External Secrets.",
		[input.kind, input.metadata.name, container.name, env.name],
	)
}

# ── Containers must not run as root ──────────────────────────────────────────

deny contains msg if {
	input.kind in workload_kinds
	spec := pod_spec(input)
	object.get(spec, ["securityContext", "runAsNonRoot"], false) != true
	msg := sprintf(
		"%s/%s: pod securityContext.runAsNonRoot must be true.",
		[input.kind, input.metadata.name],
	)
}

deny contains msg if {
	input.kind in workload_kinds
	some container in all_containers(input)
	object.get(container, ["securityContext", "allowPrivilegeEscalation"], true) != false
	msg := sprintf(
		"%s/%s container %q: allowPrivilegeEscalation must be false.",
		[input.kind, input.metadata.name, container.name],
	)
}

deny contains msg if {
	input.kind in workload_kinds
	some container in all_containers(input)
	caps := object.get(container, ["securityContext", "capabilities", "drop"], [])
	not "ALL" in caps
	msg := sprintf(
		"%s/%s container %q: must drop ALL capabilities.",
		[input.kind, input.metadata.name, container.name],
	)
}

# ── Resource limits ──────────────────────────────────────────────────────────
# An unbounded container on a shared node is a noisy-neighbour incident waiting
# for load.

deny contains msg if {
	input.kind in {"Deployment", "StatefulSet"}
	some container in all_containers(input)
	not container.resources.limits.memory
	msg := sprintf(
		"%s/%s container %q: no memory limit.",
		[input.kind, input.metadata.name, container.name],
	)
}

# ── The Cloud SQL proxy must be a native sidecar ─────────────────────────────
# An ordinary init container never exits, so the pod would hang at init forever.
# See docs/90-adr/ADR-002.

deny contains msg if {
	input.kind == "Deployment"
	spec := pod_spec(input)
	some container in object.get(spec, "initContainers", [])
	contains(container.image, "cloud-sql-proxy")
	object.get(container, "restartPolicy", "") != "Always"
	msg := sprintf(
		"%s/%s: the cloud-sql-proxy init container needs restartPolicy: Always to be a sidecar (Kubernetes >= 1.29). Without it the pod never leaves Init.",
		[input.kind, input.metadata.name],
	)
}

# ── The load balancer must probe the health port ─────────────────────────────
# Probing the app port reports the process, not whether Postgres, Redis and
# object storage are reachable.

deny contains msg if {
	input.kind == "HealthCheckPolicy"
	input.spec.default.config.httpHealthCheck.port == 3000
	msg := sprintf(
		"HealthCheckPolicy/%s: health checks must target the health port (8080), not the app port (3000).",
		[input.metadata.name],
	)
}

# ── WebSocket backend timeout ────────────────────────────────────────────────
# Google's default is 30s, which severs idle WebSockets. Buzz holds them open
# for hours.

deny contains msg if {
	input.kind == "GCPBackendPolicy"
	timeout := object.get(input.spec.default, "timeoutSec", 30)
	timeout < 3600
	not input.spec.default.iap
	msg := sprintf(
		"GCPBackendPolicy/%s: timeoutSec is %d. Long-lived WebSockets need 3600; below that clients disconnect on idle.",
		[input.metadata.name, timeout],
	)
}

# ── Warnings ─────────────────────────────────────────────────────────────────

warn contains msg if {
	input.kind == "Deployment"
	input.metadata.labels["app.kubernetes.io/name"] == "buzz"
	input.spec.replicas < 2
	msg := sprintf(
		"Deployment/%s: replicas is %d. Single-replica is dev-only; there is no availability during a rollout.",
		[input.metadata.name, input.spec.replicas],
	)
}

warn contains msg if {
	input.kind == "StatefulSet"
	input.metadata.labels["app.kubernetes.io/component"] == "object-storage"
	input.spec.replicas < 4
	msg := sprintf(
		"StatefulSet/%s: %d MinIO server(s). Below 4 there is no erasure coding, so a single disk loss is data loss.",
		[input.metadata.name, input.spec.replicas],
	)
}
