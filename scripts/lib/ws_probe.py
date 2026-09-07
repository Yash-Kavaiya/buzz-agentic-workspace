#!/usr/bin/env python3
"""Verify a Buzz relay completes a WebSocket handshake and issues NIP-42 AUTH.

Written against the standard library only. A verification tool that needs its
own dependency tree is one more thing to install on the machine where something
has already gone wrong.

Two things are being checked, and the second is the interesting one:

  1. The endpoint upgrades HTTP to WebSocket (HTTP 101 with a correct
     Sec-WebSocket-Accept). This exercises DNS, TLS, Cloud Armor, the Gateway
     and the relay's app listener in one shot.

  2. The relay sends a NIP-42 ["AUTH", <challenge>] frame. That proves the
     relay is actually a Buzz relay enforcing authentication, not a load
     balancer happily terminating a connection to nothing, and not a relay
     with authentication accidentally disabled.

A relay that upgrades but never challenges is a finding, not a pass: it means
BUZZ_REQUIRE_AUTH_TOKEN is off and anyone who can reach the socket can read.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import socket
import ssl
import sys
from urllib.parse import urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def build_handshake(host: str, path: str, key: str) -> bytes:
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "User-Agent: buzzctl-verify/1.0\r\n"
        "\r\n"
    )
    return request.encode("ascii")


def expected_accept(key: str) -> str:
    digest = hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def read_until(sock: socket.socket, terminator: bytes, limit: int = 65536) -> bytes:
    buffer = b""
    while terminator not in buffer:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buffer += chunk
        if len(buffer) > limit:
            break
    return buffer


def decode_frame(payload: bytes) -> tuple[int, bytes, bytes]:
    """Decode one server-to-client frame.

    Only what a relay's first frame can be: a single unmasked text or close
    frame with a 7-bit or 16-bit length. Anything larger or fragmented is not
    something this probe needs to understand.
    """
    if len(payload) < 2:
        return 0, b"", payload

    opcode = payload[0] & 0x0F
    masked = bool(payload[1] & 0x80)
    length = payload[1] & 0x7F
    offset = 2

    if length == 126:
        if len(payload) < 4:
            return 0, b"", payload
        length = int.from_bytes(payload[2:4], "big")
        offset = 4
    elif length == 127:
        if len(payload) < 10:
            return 0, b"", payload
        length = int.from_bytes(payload[2:10], "big")
        offset = 10

    if masked:
        # Servers must not mask. If one does, decode anyway rather than
        # reporting a spurious protocol failure.
        mask = payload[offset:offset + 4]
        offset += 4
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload[offset:offset + length]))
    else:
        body = payload[offset:offset + length]

    return opcode, body, payload[offset + length:]


def probe(url: str, timeout: float, insecure: bool) -> int:
    parsed = urlparse(url)
    secure = parsed.scheme in ("wss", "https")
    host = parsed.hostname
    if not host:
        print(f"error: {url!r} has no host", file=sys.stderr)
        return 2
    port = parsed.port or (443 if secure else 80)
    path = parsed.path or "/"

    key = base64.b64encode(os.urandom(16)).decode("ascii")

    try:
        raw = socket.create_connection((host, port), timeout=timeout)
    except OSError as exc:
        print(f"error: could not connect to {host}:{port} — {exc}", file=sys.stderr)
        return 1

    try:
        if secure:
            context = ssl.create_default_context()
            if insecure:
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE
            try:
                sock = context.wrap_socket(raw, server_hostname=host)
            except ssl.SSLError as exc:
                print(f"error: TLS handshake failed — {exc}", file=sys.stderr)
                print("       If the certificate is still provisioning, Certificate",
                      file=sys.stderr)
                print("       Manager needs the DNS authorization record in the zone.",
                      file=sys.stderr)
                return 1
        else:
            sock = raw

        sock.settimeout(timeout)
        sock.sendall(build_handshake(f"{host}:{port}" if parsed.port else host, path, key))

        response = read_until(sock, b"\r\n\r\n")
        head, _, rest = response.partition(b"\r\n\r\n")
        headers = head.decode("latin-1", errors="replace")
        status_line = headers.split("\r\n", 1)[0]

        if "101" not in status_line:
            print(f"error: the server did not upgrade the connection: {status_line}",
                  file=sys.stderr)
            if "403" in status_line:
                print("       403 usually means Cloud Armor blocked the request —",
                      file=sys.stderr)
                print("       check allowed_source_ranges and the rate-limit rule.",
                      file=sys.stderr)
            if "502" in status_line or "503" in status_line:
                print("       5xx from the load balancer means no healthy backend.",
                      file=sys.stderr)
                print("       The relay is probably not passing its readiness probe.",
                      file=sys.stderr)
            return 1

        accept = ""
        for line in headers.split("\r\n")[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "sec-websocket-accept":
                accept = value.strip()
        if accept != expected_accept(key):
            print("error: Sec-WebSocket-Accept did not match. Something between the",
                  file=sys.stderr)
            print("       client and the relay is terminating the WebSocket rather",
                  file=sys.stderr)
            print("       than proxying it.", file=sys.stderr)
            return 1

        print(f"handshake ok  ({status_line})")

        # The relay sends its AUTH challenge unprompted on connect.
        buffer = rest
        for _ in range(4):
            if len(buffer) >= 2:
                opcode, body, remainder = decode_frame(buffer)
                if body:
                    buffer = remainder
                    if opcode == 0x8:
                        print("error: the relay closed the connection immediately.",
                              file=sys.stderr)
                        return 1
                    if opcode in (0x1, 0x2):
                        text = body.decode("utf-8", errors="replace")
                        try:
                            message = json.loads(text)
                        except json.JSONDecodeError:
                            print(f"error: unexpected non-JSON frame: {text[:200]}",
                                  file=sys.stderr)
                            return 1
                        if isinstance(message, list) and message and message[0] == "AUTH":
                            challenge = message[1] if len(message) > 1 else ""
                            print(f"NIP-42 AUTH challenge received ({challenge[:16]}...)")
                            return 0
                        print(f"note: first frame was {message[0] if message else '?'}, "
                              "not AUTH", file=sys.stderr)
                        continue
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buffer += chunk

        print("error: connected, but the relay never issued a NIP-42 AUTH challenge.",
              file=sys.stderr)
        print("       Check BUZZ_REQUIRE_AUTH_TOKEN — a relay that does not",
              file=sys.stderr)
        print("       challenge is a relay anyone who reaches the socket can read.",
              file=sys.stderr)
        return 1

    finally:
        try:
            sock.close()  # type: ignore[possibly-undefined]
        except Exception:
            raw.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("url", help="wss://relay.example.com")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--insecure", action="store_true",
                        help="skip certificate verification (diagnostics only)")
    args = parser.parse_args()
    return probe(args.url, args.timeout, args.insecure)


if __name__ == "__main__":
    sys.exit(main())
