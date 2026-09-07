#!/usr/bin/env python3
"""Emit an ad-hoc Job manifest that runs the object-storage conformance probe.

`buzzctl preflight` needs to run the probe on demand against a live cluster,
outside the Helm release. Rather than duplicating the chart's Job template,
this builds the equivalent manifest and prints it for `kubectl apply -f -`.

The probe script itself is mounted from a ConfigMap the caller creates from
helm/buzz-gke/files/storage_conformance.py, so there is exactly one copy of
the logic in the repository.
"""

from __future__ import annotations

import argparse
import json
import sys


def build(name: str, namespace: str, release: str, image: str,
          secret: str, bucket: str, region: str,
          writers: int, rounds: int) -> dict:
    minio_service = release if "buzz" in release else f"{release}-buzz"
    endpoint = f"http://{minio_service}-minio.{namespace}.svc.cluster.local:9000"

    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": {
                "buzz.io/job": "preflight",
                "app.kubernetes.io/part-of": "buzz",
            },
        },
        "spec": {
            "backoffLimit": 0,
            "activeDeadlineSeconds": 600,
            "template": {
                "metadata": {"labels": {"buzz.io/job": "preflight"}},
                "spec": {
                    "restartPolicy": "Never",
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 65532,
                        "runAsGroup": 65532,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "containers": [
                        {
                            "name": "conformance",
                            "image": image,
                            "securityContext": {
                                "allowPrivilegeEscalation": False,
                                "capabilities": {"drop": ["ALL"]},
                            },
                            "command": ["/bin/sh", "-c"],
                            "args": [
                                "set -eu\n"
                                "pip install --quiet --target /tmp/pylib boto3 >/dev/null\n"
                                "PYTHONPATH=/tmp/pylib python3 /probe/storage_conformance.py\n"
                            ],
                            "env": [
                                {"name": "BUZZ_S3_ENDPOINT", "value": endpoint},
                                {"name": "BUZZ_S3_BUCKET", "value": bucket},
                                {"name": "BUZZ_S3_REGION", "value": region},
                                {"name": "BUZZ_S3_ADDRESSING_STYLE", "value": "path"},
                                {"name": "PROBE_WRITERS", "value": str(writers)},
                                {"name": "PROBE_ROUNDS", "value": str(rounds)},
                                {"name": "HOME", "value": "/tmp"},
                                {
                                    "name": "BUZZ_S3_ACCESS_KEY",
                                    "valueFrom": {"secretKeyRef": {
                                        "name": secret, "key": "BUZZ_S3_ACCESS_KEY"}},
                                },
                                {
                                    "name": "BUZZ_S3_SECRET_KEY",
                                    "valueFrom": {"secretKeyRef": {
                                        "name": secret, "key": "BUZZ_S3_SECRET_KEY"}},
                                },
                            ],
                            "volumeMounts": [
                                {"name": "probe", "mountPath": "/probe", "readOnly": True},
                                {"name": "scratch", "mountPath": "/tmp"},
                            ],
                            "resources": {
                                "requests": {"cpu": "200m", "memory": "256Mi"},
                                "limits": {"cpu": "2", "memory": "1Gi"},
                            },
                        }
                    ],
                    "volumes": [
                        {"name": "probe", "configMap": {"name": name}},
                        {"name": "scratch", "emptyDir": {"sizeLimit": "512Mi"}},
                    ],
                },
            },
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--image", default="python:3.12-slim")
    parser.add_argument("--secret", default="buzz-secrets")
    parser.add_argument("--bucket", default="buzz-media")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--writers", type=int, default=32)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()

    manifest = build(args.name, args.namespace, args.release, args.image,
                     args.secret, args.bucket, args.region,
                     args.writers, args.rounds)
    # JSON is valid YAML, and avoids depending on PyYAML in this path.
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
