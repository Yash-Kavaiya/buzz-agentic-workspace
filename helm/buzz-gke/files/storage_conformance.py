#!/usr/bin/env python3
"""Object-store conditional-write conformance probe for Buzz.

Buzz hosts git repositories on object storage with no persistent filesystem.
Every repository's state is a set of immutable, content-addressed pack objects
plus one mutable *manifest pointer*. Concurrent pushes are serialised by a
single primitive: a conditional PUT of that pointer, predicated on the ETag the
pusher read (``If-Match``), or on the object's absence (``If-None-Match: *``).

That is the whole of the writer serialisation. If the backend does not
implement those preconditions with linearizable semantics, concurrent pushes
silently lose updates -- so the relay probes for it at startup and treats
failure as fatal. A non-conforming store therefore does not degrade: it
produces a relay that starts, never becomes Ready, and reports a probe failure
most operators have never seen before.

This script runs the same four phases *before* deployment, against the
configured endpoint, and says in plain language which one failed.

Phases (mirroring crates/buzz-relay/src/api/git/store.rs in block/buzz):

  1. sequential          -- the semantics, one request at a time
  2. if_match_race       -- N concurrent If-Match, exactly one may win
  3. if_none_match_race  -- N concurrent create-only, exactly one may win
  4. etag_consistency    -- HEAD and GET must report the same ETag token

Phases 2 and 3 are the load-bearing ones. The axiom is a claim about races, so
a probe that only checks sequential behaviour cannot admit a backend.

Exit codes:
  0  every phase passed; the backend is admitted
  1  a phase failed; the report names which and why
  2  the probe could not run (configuration, connectivity, credentials)
"""

from __future__ import annotations

import json
import os
import secrets
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import quote

try:
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest
    from botocore.credentials import Credentials
    from botocore.httpsession import URLLib3Session
except ImportError:  # pragma: no cover - environment problem, not a test failure
    print("botocore is required: pip install boto3", file=sys.stderr)
    raise SystemExit(2)


# Requests are built and signed by hand rather than through boto3's client.
# The probe has to control the exact bytes of the If-Match token -- the
# specification requires comparing it literally, quotes included -- and boto3
# has changed how it exposes conditional headers across versions. Signing
# directly removes that variable.
class Store:
    def __init__(
        self,
        endpoint: str,
        bucket: str,
        region: str,
        access_key: str,
        secret_key: str,
        addressing_style: str = "path",
        verify: bool = True,
    ) -> None:
        self.endpoint = endpoint.rstrip("/")
        self.bucket = bucket
        self.region = region
        self.addressing_style = addressing_style
        self._creds = Credentials(access_key, secret_key)
        self._session = URLLib3Session(verify=verify, timeout=30)

    def _url(self, key: str) -> str:
        encoded = quote(key, safe="/")
        if self.addressing_style == "virtual":
            scheme, _, host = self.endpoint.partition("://")
            return f"{scheme}://{self.bucket}.{host}/{encoded}"
        return f"{self.endpoint}/{self.bucket}/{encoded}"

    def request(
        self,
        method: str,
        key: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        request = AWSRequest(
            method=method,
            url=self._url(key),
            data=body,
            headers=headers or {},
        )
        SigV4Auth(self._creds, "s3", self.region).add_auth(request)
        response = self._session.send(request.prepare())
        payload = response.content or b""
        return response.status_code, dict(response.headers), payload

    def put(self, key: str, body: bytes, *, if_match: str | None = None,
            if_none_match: str | None = None) -> tuple[int, str | None]:
        headers = {"Content-Type": "application/octet-stream"}
        if if_match is not None:
            headers["If-Match"] = if_match
        if if_none_match is not None:
            headers["If-None-Match"] = if_none_match
        status, response_headers, _ = self.request("PUT", key, body, headers)
        return status, response_headers.get("ETag") or response_headers.get("etag")

    def get(self, key: str) -> tuple[int, str | None, bytes]:
        status, headers, body = self.request("GET", key)
        return status, headers.get("ETag") or headers.get("etag"), body

    def head(self, key: str) -> tuple[int, str | None]:
        status, headers, _ = self.request("HEAD", key)
        return status, headers.get("ETag") or headers.get("etag")

    def delete(self, key: str) -> int:
        status, _, _ = self.request("DELETE", key)
        return status

    def list_bucket(self) -> tuple[int, bytes]:
        """Bucket-level LIST, used only to check reachability and credentials.

        Goes through a separate path from `request` because the key encoder
        would percent-escape the query string into an object name.
        """
        if self.addressing_style == "virtual":
            scheme, _, host = self.endpoint.partition("://")
            url = f"{scheme}://{self.bucket}.{host}/?list-type=2&max-keys=1"
        else:
            url = f"{self.endpoint}/{self.bucket}?list-type=2&max-keys=1"

        request = AWSRequest(method="GET", url=url)
        SigV4Auth(self._creds, "s3", self.region).add_auth(request)
        response = self._session.send(request.prepare())
        return response.status_code, response.content or b""


@dataclass
class PhaseResult:
    phase: str
    passed: bool
    detail: str = ""
    observations: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "phase": self.phase,
            "status": "pass" if self.passed else "fail",
            "detail": self.detail,
            "observations": self.observations,
        }


# A precondition failure is 412. Some implementations answer a create-only
# collision with 409 Conflict; both mean "the precondition stopped the write",
# which is the property under test.
PRECONDITION_FAILED = (409, 412)


def phase_sequential(store: Store, prefix: str) -> PhaseResult:
    key = f"{prefix}/sequential"
    obs: list[str] = []

    store.delete(key)

    status, etag = store.put(key, b"first", if_none_match="*")
    if status not in (200, 201):
        return PhaseResult(
            "sequential", False,
            f"create-only PUT on an absent key returned {status}; expected success.",
            obs,
        )
    if not etag:
        return PhaseResult(
            "sequential", False,
            "the store did not return an ETag on write. The manifest pointer CAS "
            "has nothing to predicate on without one.",
            obs,
        )
    obs.append(f"create-only PUT succeeded, ETag={etag}")

    status, _ = store.put(key, b"second", if_none_match="*")
    if status not in PRECONDITION_FAILED:
        return PhaseResult(
            "sequential", False,
            f"a second If-None-Match:* PUT on an existing key returned {status}; "
            "expected a precondition failure. The store is ignoring the header, "
            "so two concurrent repository creations would both believe they won.",
            obs,
        )
    obs.append("duplicate create-only PUT correctly refused")

    status, new_etag = store.put(key, b"third", if_match=etag)
    if status not in (200, 201):
        return PhaseResult(
            "sequential", False,
            f"If-Match with the current ETag returned {status}; expected success.",
            obs,
        )
    obs.append(f"If-Match with current ETag succeeded, ETag={new_etag}")

    status, _ = store.put(key, b"fourth", if_match=etag)
    if status not in PRECONDITION_FAILED:
        return PhaseResult(
            "sequential", False,
            f"If-Match with a STALE ETag returned {status}; expected a "
            "precondition failure. This is the single most important check: a "
            "store that accepts a stale If-Match silently loses git pushes.",
            obs,
        )
    obs.append("stale If-Match correctly refused")

    missing = f"{prefix}/never-created"
    store.delete(missing)
    status, _ = store.put(missing, b"should-not-exist", if_match='"deadbeef"')
    if status not in PRECONDITION_FAILED + (404,):
        return PhaseResult(
            "sequential", False,
            f"If-Match against a missing key returned {status}; it must not create.",
            obs,
        )
    get_status, _, _ = store.get(missing)
    if get_status == 200:
        return PhaseResult(
            "sequential", False,
            "If-Match against a missing key CREATED the object.",
            obs,
        )
    obs.append("If-Match on a missing key correctly did not create")

    status, _, body = store.get(key)
    if status != 200 or body != b"third":
        return PhaseResult(
            "sequential", False,
            f"read-after-write returned {body!r}; expected b'third'.",
            obs,
        )
    obs.append("read-after-write is consistent")

    store.delete(key)
    store.delete(missing)
    return PhaseResult("sequential", True, "conditional-write semantics are correct", obs)


def _race(store: Store, key: str, width: int, header: str, token: str) -> list[tuple[int, bytes]]:
    """Fire `width` conditional writes at one key simultaneously.

    Each writer sends a distinct body so the winner can be identified from the
    stored bytes alone -- which is what proves the surviving value belongs to
    the writer the store reported as successful.
    """
    payloads = [f"writer-{i}-{secrets.token_hex(8)}".encode() for i in range(width)]

    def attempt(body: bytes) -> tuple[int, bytes]:
        kwargs = {"if_match": token} if header == "If-Match" else {"if_none_match": token}
        status, _ = store.put(key, body, **kwargs)
        return status, body

    with ThreadPoolExecutor(max_workers=width) as pool:
        # list() forces every future to complete before the pool is torn down.
        return list(pool.map(attempt, payloads))


def _judge_race(
    store: Store,
    key: str,
    results: list[tuple[int, bytes]],
    round_index: int,
    header: str,
) -> tuple[bool, str]:
    winners = [(s, b) for s, b in results if s in (200, 201)]
    refused = [(s, b) for s, b in results if s in PRECONDITION_FAILED]
    other = [(s, b) for s, b in results if s not in (200, 201) + PRECONDITION_FAILED]

    if other:
        codes = sorted({s for s, _ in other})
        return False, (
            f"round {round_index}: {len(other)} writer(s) returned unexpected "
            f"status {codes}. Neither a win nor a clean precondition failure "
            "leaves the pusher unable to tell whether its push landed."
        )

    if len(winners) == 0:
        return False, (
            f"round {round_index}: every concurrent {header} write was refused. "
            "The store is not making progress under contention; git pushes "
            "would deadlock rather than serialise."
        )

    if len(winners) > 1:
        return False, (
            f"round {round_index}: {len(winners)} concurrent {header} writes "
            "ALL succeeded. The store is not enforcing the precondition "
            "atomically. Concurrent git pushes to the same repository would "
            "each believe they won and silently overwrite each other. This is "
            "the exact failure mode that makes Google Cloud Storage's "
            "S3-compatible API unusable as a Buzz backend."
        )

    _, winning_body = winners[0]
    status, _, stored = store.get(key)
    if status != 200:
        return False, f"round {round_index}: could not read the key back (status {status})."

    if stored != winning_body:
        losing = {b for _, b in refused}
        if stored in losing:
            return False, (
                f"round {round_index}: the stored value belongs to a writer the "
                "store REFUSED. A losing write was applied anyway."
            )
        return False, (
            f"round {round_index}: the stored value matches no writer's payload."
        )

    return True, f"round {round_index}: exactly one winner, {len(refused)} refused, value is the winner's"


def phase_if_match_race(store: Store, prefix: str, width: int, rounds: int) -> PhaseResult:
    key = f"{prefix}/if-match-race"
    obs: list[str] = []

    for round_index in range(1, rounds + 1):
        store.delete(key)
        status, etag = store.put(key, b"base", if_none_match="*")
        if status not in (200, 201) or not etag:
            return PhaseResult(
                "if_match_race", False,
                f"could not establish the base object for round {round_index} "
                f"(status {status}).", obs,
            )

        results = _race(store, key, width, "If-Match", etag)
        ok, detail = _judge_race(store, key, results, round_index, "If-Match")
        obs.append(detail)
        if not ok:
            return PhaseResult("if_match_race", False, detail, obs)

    store.delete(key)
    return PhaseResult(
        "if_match_race", True,
        f"{width} concurrent writers x {rounds} rounds: exactly one winner every time",
        obs,
    )


def phase_if_none_match_race(store: Store, prefix: str, width: int, rounds: int) -> PhaseResult:
    obs: list[str] = []

    for round_index in range(1, rounds + 1):
        # A fresh key each round: the property under test is creation of an
        # absent object, so reusing a key would test the wrong thing.
        key = f"{prefix}/if-none-match-race-{round_index}-{secrets.token_hex(4)}"
        store.delete(key)

        results = _race(store, key, width, "If-None-Match", "*")
        ok, detail = _judge_race(store, key, results, round_index, "If-None-Match")
        obs.append(detail)
        store.delete(key)
        if not ok:
            return PhaseResult("if_none_match_race", False, detail, obs)

    return PhaseResult(
        "if_none_match_race", True,
        f"{width} concurrent creators x {rounds} rounds: exactly one winner every time",
        obs,
    )


def phase_etag_consistency(store: Store, prefix: str) -> PhaseResult:
    key = f"{prefix}/etag-consistency"
    store.delete(key)

    put_status, put_etag = store.put(key, b"etag-token-check", if_none_match="*")
    if put_status not in (200, 201):
        return PhaseResult("etag_consistency", False, f"setup PUT returned {put_status}.")

    head_status, head_etag = store.head(key)
    get_status, get_etag, _ = store.get(key)
    store.delete(key)

    if head_status != 200 or get_status != 200:
        return PhaseResult(
            "etag_consistency", False,
            f"HEAD returned {head_status}, GET returned {get_status}.",
        )

    # Compared byte for byte, quotes included. If-Match compares the token
    # literally, so a store that quotes on one path and not the other would
    # make every CAS predicate compare the wrong string -- and the failure
    # would look like random push rejections, not a configuration error.
    if head_etag != get_etag:
        return PhaseResult(
            "etag_consistency", False,
            f"HEAD reports ETag {head_etag!r} but GET reports {get_etag!r}. "
            "The tokens must agree byte for byte, quoting included.",
        )

    if put_etag and put_etag != get_etag:
        return PhaseResult(
            "etag_consistency", False,
            f"PUT reported ETag {put_etag!r} but GET reports {get_etag!r}.",
        )

    return PhaseResult(
        "etag_consistency", True,
        f"HEAD, GET and PUT agree on the ETag token ({get_etag})",
    )


def env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        print(f"error: {name} is not set", file=sys.stderr)
        raise SystemExit(2)
    return value or ""


def main() -> int:
    endpoint = env("BUZZ_S3_ENDPOINT", required=True)
    bucket = env("BUZZ_S3_BUCKET", required=True)
    region = env("BUZZ_S3_REGION", "us-east-1")
    access_key = env("BUZZ_S3_ACCESS_KEY", required=True)
    secret_key = env("BUZZ_S3_SECRET_KEY", required=True)
    addressing = env("BUZZ_S3_ADDRESSING_STYLE", "path")
    width = int(env("PROBE_WRITERS", "32"))
    rounds = int(env("PROBE_ROUNDS", "3"))
    verify_tls = env("PROBE_VERIFY_TLS", "true").lower() != "false"

    store = Store(endpoint, bucket, region, access_key, secret_key, addressing, verify_tls)
    prefix = f"_buzz_preflight/{int(time.time())}-{secrets.token_hex(4)}"

    print("Buzz object-storage conformance probe")
    print(f"  endpoint   {endpoint}")
    print(f"  bucket     {bucket}  (region {region}, {addressing}-style addressing)")
    print(f"  contention {width} writers x {rounds} rounds")
    print()

    # Fail fast and clearly if the bucket is simply unreachable, rather than
    # reporting a conformance failure for what is really a credentials problem.
    status, body = store.list_bucket()
    if status in (401, 403):
        print(f"error: the credentials were rejected ({status}). Check "
              "BUZZ_S3_ACCESS_KEY / BUZZ_S3_SECRET_KEY and the bucket policy.",
              file=sys.stderr)
        return 2
    if status == 404:
        print(f"error: bucket {bucket!r} does not exist at {endpoint}.", file=sys.stderr)
        return 2
    if status >= 500:
        print(f"error: the store returned {status}: {body[:200]!r}", file=sys.stderr)
        return 2

    results = [
        phase_sequential(store, prefix),
        phase_if_match_race(store, prefix, width, rounds),
        phase_if_none_match_race(store, prefix, width, rounds),
        phase_etag_consistency(store, prefix),
    ]

    for result in results:
        mark = "PASS" if result.passed else "FAIL"
        print(f"[{mark}] {result.phase}: {result.detail}")
        for observation in result.observations:
            print(f"       {observation}")

    print()
    report = {
        "endpoint": endpoint,
        "bucket": bucket,
        "writers": width,
        "rounds": rounds,
        "phases": [r.as_dict() for r in results],
        "admitted": all(r.passed for r in results),
    }
    print(json.dumps(report, indent=2))

    if report["admitted"]:
        print()
        print("Backend admitted. Buzz's manifest-pointer CAS is safe against this store.")
        return 0

    print()
    print("Backend REJECTED. Do not deploy the relay against this store: it would",
          file=sys.stderr)
    print("start, fail its own startup conformance probe, and never become Ready.",
          file=sys.stderr)
    print("See docs/90-adr/ADR-001-object-storage.md for why this gate exists.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
