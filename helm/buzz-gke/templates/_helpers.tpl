{{/*
Common naming and label helpers.

The relay's own resources are named by the upstream chart; anything this chart
creates is prefixed "<release>-gke-" so the two never collide.
*/}}

{{- define "buzz-gke.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "buzz-gke.fullname" -}}
{{- if contains "buzz" .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-buzz" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Name of the relay Service created by the upstream subchart. Mirrors that
chart's buzz.fullname so HTTPRoutes and policies can target it. If upstream
ever changes its helper, this is the one place to follow.
*/}}
{{- define "buzz-gke.relayServiceName" -}}
{{- include "buzz-gke.fullname" . -}}
{{- end -}}

{{- define "buzz-gke.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "buzz-gke.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: buzz
{{- end -}}

{{- define "buzz-gke.minio.fullname" -}}
{{- printf "%s-minio" (include "buzz-gke.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "buzz-gke.minio.labels" -}}
{{ include "buzz-gke.labels" . }}
app.kubernetes.io/component: object-storage
{{- end -}}

{{- define "buzz-gke.minio.selectorLabels" -}}
app.kubernetes.io/name: {{ include "buzz-gke.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: object-storage
{{- end -}}

{{/*
Internal MinIO endpoint the relay dials. Path-style addressing is mandatory:
the headless Service resolves one hostname, never <bucket>.<service>.
*/}}
{{- define "buzz-gke.minio.endpoint" -}}
{{- printf "http://%s.%s.svc.cluster.local:9000" (include "buzz-gke.minio.fullname" .) .Release.Namespace -}}
{{- end -}}

{{/*
Fully-qualified Secret Manager resource name for a logical secret key.
*/}}
{{- define "buzz-gke.secretResource" -}}
{{- $ctx := .ctx -}}
{{- printf "%s-%s" $ctx.Values.gcp.namePrefix .suffix -}}
{{- end -}}

{{/*
Fail early and loudly on the values that cannot be defaulted. A missing one of
these produces a deployment that installs and then misbehaves in ways that are
expensive to diagnose, so refusing to render is the kinder outcome.
*/}}
{{- define "buzz-gke.validate" -}}
{{- if not .Values.gcp.projectId -}}
{{- fail "gcp.projectId is required. It comes from `terraform output platform`; run `buzzctl deploy <env>` rather than helm directly." -}}
{{- end -}}
{{- if not .Values.gcp.namePrefix -}}
{{- fail "gcp.namePrefix is required (e.g. buzz-prod). It prefixes every Secret Manager id this chart reads." -}}
{{- end -}}
{{- if .Values.buzz.enabled -}}
{{- if not .Values.buzz.relayUrl -}}
{{- fail "buzz.relayUrl is required (wss://<host>)." -}}
{{- end -}}
{{- if not .Values.buzz.ownerPubkey -}}
{{- fail "buzz.ownerPubkey is required: with requireRelayMembership on, a relay with no owner is a relay nobody can join. Generate one with `buzzctl keygen`." -}}
{{- end -}}
{{- if and (not .Values.buzz.image.digest) (not .Values.buzz.image.tag) -}}
{{- fail "buzz.image.digest is required. Run `buzzctl images mirror <env>` to mirror and pin the relay image." -}}
{{- end -}}
{{- if gt (int .Values.buzz.replicaCount) 1 -}}
{{- if .Values.buzz.redis.enabled -}}
{{- fail "buzz.redis.enabled must be false: replicaCount > 1 requires the external Memorystore instance, not the bundled eval Redis." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and .Values.minio.enabled (lt (int .Values.minio.replicas) 4) -}}
{{- if ne (int .Values.minio.replicas) 1 -}}
{{- fail "minio.replicas must be 1 (single-node, eval only) or >= 4 (erasure coded). 2 or 3 gives neither redundancy nor a valid erasure set." -}}
{{- end -}}
{{- end -}}
{{- end -}}
