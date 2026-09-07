#!/usr/bin/env python3
"""Tests for the Terraform-output to Helm-values renderer.

The renderer is the seam where a mistake is expensive and quiet: a wrong
ServiceAccount annotation produces a relay that cannot reach Cloud SQL, a
missing sidecar produces a relay that cannot reach it at all, and neither
announces itself as a rendering bug.

Run: python3 tests/test_render_values.py
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parent.parent / "scripts" / "lib" / "render_values.py"
spec = importlib.util.spec_from_file_location("render_values", MODULE)
assert spec and spec.loader
render_values = importlib.util.module_from_spec(spec)
sys.modules["render_values"] = render_values
spec.loader.exec_module(render_values)


PLATFORM = {
    "environment": "prod",
    "project_id": "acme-buzz",
    "region": "us-central1",
    "name_prefix": "buzz-prod",
    "namespace": "buzz",
    "release": "buzz",
    "cluster": {"name": "buzz-prod", "location": "us-central1"},
    "identity": {
        "relay_ksa": "buzz-relay",
        "relay_service_account": "buzz-prod-relay@acme-buzz.iam.gserviceaccount.com",
        "external_secrets_service_account": "buzz-prod-eso@acme-buzz.iam.gserviceaccount.com",
        "minio_backup_service_account": "buzz-prod-minio-backup@acme-buzz.iam.gserviceaccount.com",
        "relay_iam_db_user": "buzz-prod-relay@acme-buzz.iam.gserviceaccount.com",
    },
    "database": {
        "connection_name": "acme-buzz:us-central1:buzz-prod-pg-a1b2c3",
        "replica_connection_name": "",
        "database": "buzz",
        "user": "buzz",
        "read_replica_enabled": False,
    },
    "redis": {"host": "10.0.0.5", "port": 6379, "transit_encryption_enabled": True},
    "edge": {
        "relay_url": "wss://buzz.example.com",
        "relay_hostname": "buzz.example.com",
        "admin_hostname": "buzz-admin.example.com",
        "gateway_ip_name": "buzz-prod-gateway-ip",
        "gateway_ip_address": "203.0.113.10",
        "certificate_map_name": "buzz-prod-certmap",
        "security_policy_name": "buzz-prod-armor",
    },
    "registry": {
        "repository_url": "us-central1-docker.pkg.dev/acme-buzz/buzz",
        "attestor_name": "buzz-prod-mirror-attestor",
    },
    "secrets": {"prefix": "buzz-prod", "ids": {}, "awaiting_buzzctl_init": []},
    "backup": {"dr_bucket": "buzz-prod-object-dr", "dr_bucket_url": "gs://buzz-prod-object-dr"},
}

CONFIG = {
    "ownerPubkey": "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
    "operators": ["aa" * 32],
    "rateLimits": {"humanMessagesPerMin": 60, "agentPlatformMessagesPerMin": 600},
    "corsOrigins": [],
}

DIGEST = "sha256:" + "ab" * 32


def check(condition: bool, message: str) -> bool:
    print(("ok   " if condition else "FAIL ") + message,
          file=sys.stdout if condition else sys.stderr)
    return condition


def env_value(env_list, name):
    for entry in env_list:
        if entry["name"] == name:
            return entry["value"]
    return None


def main() -> int:
    failures = 0
    ca = "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----"
    values = render_values.build(PLATFORM, CONFIG, DIGEST, ca, "buzz")

    buzz = values["buzz"]

    failures += not check(buzz["image"]["digest"] == DIGEST,
                          "the image is pinned by digest")
    failures += not check("tag" not in buzz["image"],
                          "no tag is emitted alongside the digest")
    failures += not check(buzz["relayUrl"] == "wss://buzz.example.com",
                          "relayUrl comes from the edge output")
    failures += not check(buzz["ownerPubkey"] == CONFIG["ownerPubkey"],
                          "ownerPubkey comes from the environment config")

    annotation = buzz["serviceAccount"]["annotations"].get("iam.gke.io/gcp-service-account")
    failures += not check(annotation == PLATFORM["identity"]["relay_service_account"],
                          "the Workload Identity annotation names the relay GSA")

    # The Cloud SQL sidecar. If this is not a restartPolicy: Always init
    # container, it is an ordinary init container that must exit before the
    # relay starts -- which it never does, so the pod would hang forever.
    sidecars = buzz["extraInitContainers"]
    failures += not check(len(sidecars) == 1, "exactly one sidecar is rendered")
    sidecar = sidecars[0]
    failures += not check(sidecar["restartPolicy"] == "Always",
                          "the Cloud SQL proxy is a native sidecar, not a blocking init container")
    failures += not check(PLATFORM["database"]["connection_name"] in sidecar["args"],
                          "the sidecar is pointed at the right instance")
    failures += not check("--address=127.0.0.1" in sidecar["args"],
                          "the proxy listens on loopback only")
    failures += not check(sidecar["securityContext"]["runAsNonRoot"] is True,
                          "the sidecar runs as non-root")

    relay_env = buzz["relay"]["extraEnv"]
    operators = env_value(relay_env, "RELAY_OPERATOR_PUBKEYS")
    failures += not check(operators is not None and CONFIG["ownerPubkey"] in operators,
                          "the owner is included in RELAY_OPERATOR_PUBKEYS")
    failures += not check(operators is not None and CONFIG["operators"][0] in operators,
                          "configured operators are included")
    failures += not check(env_value(relay_env, "BUZZ_ADMIN_HOST") == "buzz-admin.example.com",
                          "the admin console host is set")
    failures += not check(
        env_value(relay_env, "RELAY_OPERATOR_API_ORIGIN") == "https://buzz-admin.example.com",
        "the operator API origin matches the admin host")
    failures += not check(env_value(relay_env, "BUZZ_RATE_LIMIT_HUMAN_MESSAGES_PER_MIN") == "60",
                          "relay rate limits are passed through")
    failures += not check(env_value(relay_env, "SSL_CERT_FILE") is not None,
                          "the Memorystore CA is pointed at when TLS is on")

    failures += not check(
        buzz["s3"]["endpoint"] == "http://buzz-minio.buzz.svc.cluster.local:9000",
        "the relay is pointed at the in-cluster MinIO service")

    route = buzz["httproute"]
    failures += not check(route["hostnames"] == ["buzz.example.com"],
                          "the relay route uses the relay hostname only")
    failures += not check(route["parentRefs"][0]["sectionName"] == "https",
                          "the route attaches to the HTTPS listener")

    failures += not check(len(buzz["extraVolumes"]) == 1,
                          "the Redis CA volume is rendered")
    failures += not check(buzz["relay"]["extraVolumeMounts"][0]["readOnly"] is True,
                          "the CA is mounted read-only")

    # With transit encryption off there must be no CA plumbing at all --
    # a dangling SSL_CERT_FILE pointing at an absent file would break TLS to
    # every other endpoint the relay talks to.
    print("\nwith Memorystore TLS disabled:")
    plain = dict(PLATFORM)
    plain["redis"] = {**PLATFORM["redis"], "transit_encryption_enabled": False}
    values_plain = render_values.build(plain, CONFIG, DIGEST, "", "buzz")
    failures += not check("extraVolumes" not in values_plain["buzz"],
                          "no CA volume is rendered")
    failures += not check(
        env_value(values_plain["buzz"]["relay"]["extraEnv"], "SSL_CERT_FILE") is None,
        "SSL_CERT_FILE is not set, so the default trust store stays intact")

    print("\nwith a read replica:")
    replica = dict(PLATFORM)
    replica["database"] = {
        **PLATFORM["database"],
        "replica_connection_name": "acme-buzz:us-central1:buzz-prod-pg-a1b2c3-replica",
        "read_replica_enabled": True,
    }
    values_replica = render_values.build(replica, CONFIG, DIGEST, ca, "buzz")
    replica_args = values_replica["buzz"]["extraInitContainers"][0]["args"]
    failures += not check("--port=5433" in replica_args,
                          "the replica gets its own local port")
    failures += not check(replica_args[-1].endswith("-replica"),
                          "the replica instance is the last argument")

    if failures:
        print(f"\n{failures} check(s) failed", file=sys.stderr)
        return 1
    print("\nall render checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
