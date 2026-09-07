#!/usr/bin/env python3
"""Render Helm values from Terraform output and per-environment config.

This is the seam between the two halves of the platform. Terraform knows the
project coordinates; config/<env>.yaml knows the identity policy; the chart
knows the shape. Rather than asking an operator to keep three files in sync by
hand, this composes the generated layer from the first two.

Everything it emits is derived. If a value here looks wrong, the fix is in
`terraform output platform` or config/<env>.yaml, never in the generated file.

Usage:
    render_values.py --platform platform.json --config config/prod.yaml \
                     --image-digest sha256:... [--redis-ca ca.pem] \
                     --output values.generated.yaml
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import yaml


# Kubernetes 1.29+ honours restartPolicy: Always on an init container, which
# makes it a *sidecar*: it starts before the app container, stays running for
# the pod's lifetime, and is torn down after the app exits. That is exactly
# what the Cloud SQL Auth Proxy needs, and it is why the upstream chart's
# extraInitContainers extension point is sufficient — no chart fork required.
CLOUD_SQL_PROXY_IMAGE = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1"


def cloud_sql_sidecar(platform: dict[str, Any]) -> list[dict[str, Any]]:
    database = platform["database"]
    connection_name = database.get("connection_name")
    if not connection_name:
        return []

    args = [
        "--structured-logs",
        # Bind to loopback only. The proxy must be reachable by the relay
        # container in the same pod and by nothing else.
        "--address=127.0.0.1",
        "--port=5432",
        # Health endpoints let Kubernetes see proxy readiness distinctly from
        # relay readiness, so a proxy that cannot reach Cloud SQL is diagnosed
        # as itself rather than as a database outage.
        "--http-address=0.0.0.0",
        "--http-port=9801",
        "--health-check",
        # Without this the relay can start, fail to connect, and crash-loop
        # while the proxy is still opening its listener.
        "--exit-zero-on-sigterm",
    ]

    if database.get("auto_iam_authn"):
        args.append("--auto-iam-authn")

    args.append(connection_name)

    if database.get("replica_connection_name"):
        # Second instance on a second port; the relay reaches it through
        # READ_DATABASE_URL pointed at 127.0.0.1:5433.
        args.insert(-1, "--port=5433")
        args.append(database["replica_connection_name"])

    return [
        {
            "name": "cloud-sql-proxy",
            "image": CLOUD_SQL_PROXY_IMAGE,
            # The field that turns an init container into a sidecar.
            "restartPolicy": "Always",
            "args": args,
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": 65532,
                "allowPrivilegeEscalation": False,
                "readOnlyRootFilesystem": True,
                "capabilities": {"drop": ["ALL"]},
            },
            "startupProbe": {
                "httpGet": {"path": "/startup", "port": 9801},
                "periodSeconds": 2,
                "failureThreshold": 60,
            },
            "livenessProbe": {
                "httpGet": {"path": "/liveness", "port": 9801},
                "periodSeconds": 10,
                "failureThreshold": 3,
            },
            "resources": {
                "requests": {"cpu": "100m", "memory": "128Mi"},
                "limits": {"cpu": "1", "memory": "512Mi"},
            },
        }
    ]


def relay_extra_env(platform: dict[str, Any], config: dict[str, Any]) -> list[dict[str, str]]:
    """Environment the upstream chart does not render itself.

    The chart covers the relay's core configuration but leaves operator
    identity, the admin host and the rate limits to the platform. Each entry
    below is a variable the relay reads that has no values.yaml key upstream.
    """
    env: list[dict[str, str]] = []

    operators = config.get("operators") or []
    owner = config.get("ownerPubkey") or ""
    # RELAY_OPERATOR_PUBKEYS overrides the owner fallback entirely, so the owner
    # has to be included explicitly or they lose console access.
    all_operators = [p for p in ([owner] + list(operators)) if p]
    if all_operators:
        env.append({
            "name": "RELAY_OPERATOR_PUBKEYS",
            "value": ",".join(dict.fromkeys(all_operators)),
        })

    admin_host = platform["edge"].get("admin_hostname")
    if admin_host:
        env.append({"name": "BUZZ_ADMIN_HOST", "value": admin_host})
        env.append({"name": "BUZZ_ADMIN_AUTH", "value": "nip98"})
        # Community provisioning verifies NIP-98 requests against this origin;
        # a mismatch rejects every admin call with an opaque auth error.
        env.append({
            "name": "RELAY_OPERATOR_API_ORIGIN",
            "value": f"https://{admin_host}",
        })

    limits = config.get("rateLimits") or {}
    limit_env = {
        "humanMessagesPerMin": "BUZZ_RATE_LIMIT_HUMAN_MESSAGES_PER_MIN",
        "humanApiCallsPerMin": "BUZZ_RATE_LIMIT_HUMAN_API_CALLS_PER_MIN",
        "humanWsEventsPerSec": "BUZZ_RATE_LIMIT_HUMAN_WS_EVENTS_PER_SEC",
        "agentStandardMessagesPerMin": "BUZZ_RATE_LIMIT_AGENT_STANDARD_MESSAGES_PER_MIN",
        "agentStandardApiCallsPerMin": "BUZZ_RATE_LIMIT_AGENT_STANDARD_API_CALLS_PER_MIN",
        "agentElevatedMessagesPerMin": "BUZZ_RATE_LIMIT_AGENT_ELEVATED_MESSAGES_PER_MIN",
        "agentPlatformMessagesPerMin": "BUZZ_RATE_LIMIT_AGENT_PLATFORM_MESSAGES_PER_MIN",
    }
    for key, name in limit_env.items():
        if key in limits and limits[key] is not None:
            env.append({"name": name, "value": str(limits[key])})

    # The hourly bucket sweep needs bucket-level s3:ListBucket, which the MinIO
    # init job grants. Left on so buzz_storage_sweep_ok is a live signal.
    env.append({"name": "BUZZ_STORAGE_METRICS", "value": "on"})

    if platform["redis"].get("transit_encryption_enabled"):
        # Memorystore presents a certificate from a Google-managed private CA.
        # rustls reads the system trust store, so the mounted bundle has to be
        # pointed at explicitly or every rediss:// handshake fails.
        env.append({"name": "SSL_CERT_FILE", "value": "/etc/buzz/redis-ca/memorystore-ca.pem"})
        env.append({"name": "SSL_CERT_DIR", "value": "/etc/buzz/redis-ca"})

    return env


def build(platform: dict[str, Any], config: dict[str, Any], image_digest: str,
          redis_ca: str, release: str) -> dict[str, Any]:
    edge = platform["edge"]
    identity = platform["identity"]
    redis = platform["redis"]
    namespace = platform["namespace"]

    minio_service = f"{release}-minio" if "buzz" in release else f"{release}-buzz-minio"
    minio_endpoint = f"http://{minio_service}.{namespace}.svc.cluster.local:9000"

    values: dict[str, Any] = {
        "gcp": {
            "projectId": platform["project_id"],
            "region": platform["region"],
            "namePrefix": platform["name_prefix"],
            "workloadIdentity": {
                "relayServiceAccount": identity["relay_service_account"],
                "minioBackupServiceAccount": identity["minio_backup_service_account"],
            },
            "cloudsql": {
                "connectionName": platform["database"]["connection_name"],
                "replicaConnectionName": platform["database"].get("replica_connection_name", ""),
                "autoIamAuthn": bool(platform["database"].get("auto_iam_authn", False)),
            },
            "edge": {
                "gatewayIpName": edge["gateway_ip_name"],
                "certificateMapName": edge["certificate_map_name"],
                "securityPolicyName": edge["security_policy_name"],
                "relayHostname": edge["relay_hostname"],
                "adminHostname": edge["admin_hostname"],
            },
            "redis": {
                "transitEncryption": bool(redis.get("transit_encryption_enabled")),
                "serverCaCertificate": redis_ca,
            },
            "backup": {
                "drBucket": platform["backup"]["dr_bucket"],
            },
        },
        "operators": config.get("operators") or [],
        "buzz": {
            "relayUrl": edge["relay_url"],
            "ownerPubkey": config.get("ownerPubkey") or "",
            "image": {
                "repository": f"{platform['registry']['repository_url']}/buzz",
                "digest": image_digest,
            },
            "serviceAccount": {
                "create": True,
                "annotations": {
                    "iam.gke.io/gcp-service-account": identity["relay_service_account"],
                },
            },
            "s3": {
                "endpoint": minio_endpoint,
            },
            "httproute": {
                "enabled": True,
                "parentRefs": [
                    {
                        "name": "buzz",
                        "namespace": namespace,
                        "sectionName": "https",
                    }
                ],
                "hostnames": [edge["relay_hostname"]],
            },
            "relay": {
                "extraEnv": relay_extra_env(platform, config),
                "corsOrigins": config.get("corsOrigins") or [],
            },
            "extraInitContainers": cloud_sql_sidecar(platform),
        },
    }

    upload = config.get("uploadRecords") or {}
    if upload.get("enabled"):
        values["buzz"]["relay"]["uploadRecords"] = True
        if upload.get("ipHeader"):
            values["buzz"]["relay"]["uploadIpHeader"] = upload["ipHeader"]

    if redis_ca:
        # The volume goes on the pod; the mount goes on the relay container.
        # Upstream keeps these as two separate extension points.
        values["buzz"]["extraVolumes"] = [
            {
                "name": "redis-ca",
                "configMap": {
                    "name": f"{release}-redis-ca" if "buzz" in release else f"{release}-buzz-redis-ca",
                },
            }
        ]
        values["buzz"]["relay"]["extraVolumeMounts"] = [
            {
                "name": "redis-ca",
                "mountPath": "/etc/buzz/redis-ca",
                "readOnly": True,
            }
        ]

    return values


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--platform", required=True, type=Path,
                        help="terraform output -json platform")
    parser.add_argument("--config", required=True, type=Path,
                        help="config/<env>.yaml")
    parser.add_argument("--image-digest", default="",
                        help="sha256:... from buzzctl images mirror")
    parser.add_argument("--redis-ca", type=Path, default=None,
                        help="Memorystore server CA PEM")
    parser.add_argument("--release", default="buzz", help="Helm release name")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    platform = json.loads(args.platform.read_text())
    # `terraform output -json <name>` yields the bare value; `terraform output
    # -json` (all outputs) wraps each in {"value": ...}. Accept either so the
    # caller cannot get it subtly wrong.
    if set(platform.keys()) == {"value", "type"} or "value" in platform and "project_id" not in platform:
        platform = platform["value"]

    config = yaml.safe_load(args.config.read_text()) or {}

    redis_ca = ""
    if args.redis_ca and args.redis_ca.exists():
        redis_ca = args.redis_ca.read_text().strip()

    if platform["redis"].get("transit_encryption_enabled") and not redis_ca:
        print(
            "warning: Memorystore transit encryption is on but no CA bundle was "
            "supplied. The relay will not be able to complete a rediss:// "
            "handshake. Run `buzzctl secrets init` to fetch it.",
            file=sys.stderr,
        )

    values = build(platform, config, args.image_digest, redis_ca, args.release)

    header = (
        "# GENERATED FILE - DO NOT EDIT.\n"
        "#\n"
        "# Rendered by scripts/lib/render_values.py from `terraform output platform`\n"
        f"# and config/{args.config.stem}.yaml. Change those, then re-run\n"
        "# `buzzctl deploy`. Edits here are overwritten on the next deploy.\n"
        "\n"
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(header + yaml.safe_dump(values, sort_keys=False, default_flow_style=False))
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
