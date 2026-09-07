#!/usr/bin/env python3
"""Parse every Terraform file and check a few platform invariants.

`terraform validate` is the real check and CI runs it. This is the fallback for
a machine without Terraform installed: it parses the HCL, which catches syntax
errors, and then asserts a handful of things that are easy to regress and
expensive to discover in production.

Run: python3 tests/lint_terraform.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import hcl2

ROOT = Path(__file__).resolve().parent.parent / "terraform"


def parse_all() -> tuple[dict[Path, dict], list[str]]:
    parsed: dict[Path, dict] = {}
    errors: list[str] = []
    for path in sorted(ROOT.rglob("*.tf")):
        try:
            with path.open() as handle:
                parsed[path] = hcl2.load(handle)
        except Exception as exc:  # hcl2 raises a variety of parse errors
            errors.append(f"{path.relative_to(ROOT.parent)}: {exc}")
    return parsed, errors


def blocks(parsed: dict[Path, dict], kind: str):
    for path, document in parsed.items():
        for block in document.get(kind, []):
            for name, body in block.items():
                yield path, name, body


def resources(parsed: dict[Path, dict], resource_type: str):
    for path, document in parsed.items():
        for block in document.get("resource", []):
            for rtype, entries in block.items():
                if rtype != resource_type:
                    continue
                for name, body in entries.items():
                    yield path, name, body


def main() -> int:
    parsed, errors = parse_all()

    if errors:
        for error in errors:
            print(f"FAIL parse: {error}", file=sys.stderr)
        return 1
    print(f"ok   {len(parsed)} Terraform file(s) parse")

    failures = 0

    def check(condition: bool, message: str) -> None:
        nonlocal failures
        if condition:
            print(f"ok   {message}")
        else:
            print(f"FAIL {message}", file=sys.stderr)
            failures += 1

    # Every variable should carry a description. An undocumented variable in a
    # platform module is a decision nobody can review.
    undocumented = [
        f"{path.relative_to(ROOT.parent)}:{name}"
        for path, name, body in blocks(parsed, "variable")
        if not body.get("description")
    ]
    check(not undocumented,
          f"every variable has a description ({len(undocumented)} missing: "
          f"{', '.join(undocumented[:5])})" if undocumented
          else "every variable has a description")

    # The cluster must be private. A public node pool in this design is not a
    # configuration choice; it is a mistake.
    for path, name, body in resources(parsed, "google_container_cluster"):
        private = body.get("private_cluster_config", [{}])
        private = private[0] if isinstance(private, list) else private
        check(str(private.get("enable_private_nodes")).lower() in ("true", "${true}"),
              f"{name}: nodes are private")
        check("workload_identity_config" in body,
              f"{name}: Workload Identity is configured")
        check("database_encryption" in body,
              f"{name}: etcd Secret encryption is configured")
        check(body.get("datapath_provider") == "ADVANCED_DATAPATH",
              f"{name}: Dataplane V2 is enabled so NetworkPolicy is enforced")

    # Cloud SQL must never get a public IP.
    for path, name, body in resources(parsed, "google_sql_database_instance"):
        settings = body.get("settings", [{}])
        settings = settings[0] if isinstance(settings, list) else settings
        ip_config = settings.get("ip_configuration", [{}])
        ip_config = ip_config[0] if isinstance(ip_config, list) else ip_config
        check(str(ip_config.get("ipv4_enabled")).lower() in ("false", "${false}"),
              f"{name}: no public IP")

    # Memorystore must always require AUTH, whatever the transit setting.
    for path, name, body in resources(parsed, "google_redis_instance"):
        check(str(body.get("auth_enabled")).lower() in ("true", "${true}"),
              f"{name}: AUTH is enabled")

    # State and DR buckets must block public access.
    for path, name, body in resources(parsed, "google_storage_bucket"):
        check(body.get("public_access_prevention") == "enforced",
              f"{name}: public access prevention enforced")
        check(str(body.get("uniform_bucket_level_access")).lower() in ("true", "${true}"),
              f"{name}: uniform bucket-level access")

    if failures:
        print(f"\n{failures} invariant(s) violated", file=sys.stderr)
        return 1
    print("\nall Terraform checks passed")
    print("note: this does not replace `terraform validate`, which CI runs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
