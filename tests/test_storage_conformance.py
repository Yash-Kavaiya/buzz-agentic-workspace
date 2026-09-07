#!/usr/bin/env python3
"""Tests for the object-storage conformance probe.

The probe is the gate that decides whether a store may back Buzz, so the thing
worth testing is not that it passes against a good store -- it is that it FAILS
against a store which ignores conditional writes. That is the exact behaviour
of the Google Cloud Storage S3-compatible API, and the reason this platform
runs MinIO.

Two in-process fake stores are used:

  ConformingStore     honours If-Match and If-None-Match atomically
  NonConformingStore  accepts every write, ignoring both headers -- GCS-shaped

The probe must admit the first and reject the second.

Run: python3 tests/test_storage_conformance.py
"""

from __future__ import annotations

import hashlib
import importlib.util
import io
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

PROBE = Path(__file__).resolve().parent.parent / "helm" / "buzz-gke" / "files" / "storage_conformance.py"
spec = importlib.util.spec_from_file_location("storage_conformance", PROBE)
assert spec and spec.loader
probe = importlib.util.module_from_spec(spec)
# Register before executing: @dataclass resolves annotations through
# sys.modules, and fails on a module loaded out of band without this.
sys.modules["storage_conformance"] = probe
spec.loader.exec_module(probe)


class _Store:
    """Shared object state behind the fake servers."""

    def __init__(self, honour_preconditions: bool) -> None:
        self.honour = honour_preconditions
        self.objects: dict[str, tuple[bytes, str]] = {}
        # One lock for the whole store. A conforming S3 makes conditional PUT
        # atomic; this is the simplest faithful model of that.
        self.lock = threading.Lock()

    @staticmethod
    def etag(body: bytes) -> str:
        return '"' + hashlib.md5(body).hexdigest() + '"'

    def put(self, key: str, body: bytes,
            if_match: str | None, if_none_match: str | None) -> tuple[int, str | None]:
        with self.lock:
            existing = self.objects.get(key)

            if self.honour:
                if if_none_match == "*" and existing is not None:
                    return 412, None
                if if_match is not None:
                    if existing is None:
                        return 412, None
                    if existing[1] != if_match:
                        return 412, None

            tag = self.etag(body)
            self.objects[key] = (body, tag)
            return 200, tag


class _Handler(BaseHTTPRequestHandler):
    store: _Store

    # Silence the default per-request stderr logging; the tests print their own.
    def log_message(self, *args) -> None:  # noqa: D102
        return

    def _key(self) -> str:
        path = urlparse(self.path).path
        # /<bucket>/<key...>
        parts = path.lstrip("/").split("/", 1)
        return parts[1] if len(parts) > 1 else ""

    def _respond(self, status: int, headers: dict[str, str] | None = None,
                 body: bytes = b"", content_length: int | None = None) -> None:
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        # Exactly one Content-Length. A HEAD advertises the body it would have
        # sent, which is why the caller can override the value.
        self.send_header("Content-Length",
                         str(len(body) if content_length is None else content_length))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def do_PUT(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        status, tag = self.store.put(
            self._key(), body,
            self.headers.get("If-Match"),
            self.headers.get("If-None-Match"),
        )
        self._respond(status, {"ETag": tag} if tag else {})

    def do_GET(self) -> None:  # noqa: N802
        key = self._key()
        if not key:
            self._respond(200, {"Content-Type": "application/xml"},
                          b"<ListBucketResult></ListBucketResult>")
            return
        with self.store.lock:
            entry = self.store.objects.get(key)
        if entry is None:
            self._respond(404)
            return
        self._respond(200, {"ETag": entry[1]}, entry[0])

    def do_HEAD(self) -> None:  # noqa: N802
        with self.store.lock:
            entry = self.store.objects.get(self._key())
        if entry is None:
            self._respond(404)
            return
        self._respond(200, {"ETag": entry[1]}, content_length=len(entry[0]))

    def do_DELETE(self) -> None:  # noqa: N802
        with self.store.lock:
            self.store.objects.pop(self._key(), None)
        self._respond(204)


def serve(honour: bool):
    store = _Store(honour)
    handler = type("Handler", (_Handler,), {"store": store})
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_port}"


def run_probe(endpoint: str, writers: int = 8, rounds: int = 2) -> tuple[int, str]:
    env = {
        "BUZZ_S3_ENDPOINT": endpoint,
        "BUZZ_S3_BUCKET": "buzz-media",
        "BUZZ_S3_REGION": "us-east-1",
        "BUZZ_S3_ACCESS_KEY": "test-access",
        "BUZZ_S3_SECRET_KEY": "test-secret",
        "BUZZ_S3_ADDRESSING_STYLE": "path",
        "PROBE_WRITERS": str(writers),
        "PROBE_ROUNDS": str(rounds),
    }
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)

    stdout, stderr = sys.stdout, sys.stderr
    captured = io.StringIO()
    sys.stdout = sys.stderr = captured
    try:
        code = probe.main()
    finally:
        sys.stdout, sys.stderr = stdout, stderr
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    return code, captured.getvalue()


def main() -> int:
    failures = 0

    print("A conforming store must be ADMITTED")
    server, endpoint = serve(honour=True)
    try:
        code, output = run_probe(endpoint)
    finally:
        server.shutdown()

    if code == 0:
        print("ok   probe exited 0 against a conforming store")
    else:
        print("FAIL probe rejected a conforming store", file=sys.stderr)
        print(output, file=sys.stderr)
        failures += 1

    for phase in ("sequential", "if_match_race", "if_none_match_race", "etag_consistency"):
        if f'"phase": "{phase}"' in output and '"status": "pass"' in output:
            print(f"ok   {phase} reported")
        else:
            print(f"FAIL {phase} missing from the report", file=sys.stderr)
            failures += 1

    print("\nA store that ignores conditional writes must be REJECTED")
    print("     (this is what the GCS S3-compatible API does)")
    server, endpoint = serve(honour=False)
    try:
        code, output = run_probe(endpoint)
    finally:
        server.shutdown()

    if code == 1:
        print("ok   probe exited 1 against a non-conforming store")
    else:
        print(f"FAIL probe returned {code} for a store that ignores preconditions",
              file=sys.stderr)
        print(output, file=sys.stderr)
        failures += 1

    if '"admitted": false' in output:
        print("ok   the report marks the backend as not admitted")
    else:
        print("FAIL the report did not mark the backend as rejected", file=sys.stderr)
        failures += 1

    # The failure has to be legible to whoever reads it at 2am, which means it
    # must name the behaviour rather than just returning non-zero.
    if "ignoring the header" in output or "not enforcing the precondition" in output:
        print("ok   the failure explains that preconditions are being ignored")
    else:
        print("FAIL the failure message does not explain the cause", file=sys.stderr)
        failures += 1

    if failures:
        print(f"\n{failures} check(s) failed", file=sys.stderr)
        return 1

    print("\nall storage conformance checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
