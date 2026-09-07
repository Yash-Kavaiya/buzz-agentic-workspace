#!/usr/bin/env python3
"""Known-answer tests for the Nostr key helper.

The point-multiplication routine in scripts/lib/nostr_key.py is hand-written,
so it is checked against published vectors rather than trusted. If any of these
fail, generated agent identities are wrong and unrecoverable -- so this file is
the gate, not a formality.

Run: python3 tests/test_nostr_key.py
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parent.parent / "scripts" / "lib" / "nostr_key.py"
spec = importlib.util.spec_from_file_location("nostr_key", MODULE)
assert spec and spec.loader
nostr_key = importlib.util.module_from_spec(spec)
# Register before executing: @dataclass resolves annotations through
# sys.modules, and fails on a module loaded out of band without this.
sys.modules["nostr_key"] = nostr_key
spec.loader.exec_module(nostr_key)


# Standard secp256k1 scalar-multiple vectors (k, x, y).
SECP256K1_VECTORS = [
    (
        1,
        0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
        0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
    ),
    (
        2,
        0xC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5,
        0x1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A,
    ),
    (
        3,
        0xF9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9,
        0x388F7B0F632DE8140FE337E62A37F3566500A99934C2231B6CB9FD7584B8E672,
    ),
    (
        0xAA5E28D6A97A2479A65527F7290311A3624D4CC0FA1578598EE3C2613BF99522,
        0x34F9460F0E4F08393D192B3C5133A6BA099AA0AD9FD54EBCCFACDFA239FF49C6,
        0x0B71EA9BD730FD8923F6D25A7A91E7DD7728A960686CB5A901BB419E0F2CA232,
    ),
]

# NIP-19 reference vector.
NPUB = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
NPUB_HEX = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"


def check(condition: bool, message: str) -> None:
    if not condition:
        print(f"FAIL {message}", file=sys.stderr)
        raise SystemExit(1)
    print(f"ok   {message}")


def main() -> int:
    for k, x, y in SECP256K1_VECTORS:
        point = nostr_key._scalar_mult(k, (nostr_key._GX, nostr_key._GY))
        check(point == (x, y), f"scalar mult k={hex(k)[:12]}... matches the published point")

    # Adding the identity, and a point to its own negation, must both behave.
    g = (nostr_key._GX, nostr_key._GY)
    check(nostr_key._point_add(None, g) == g, "identity + G = G")
    check(nostr_key._point_add(g, None) == g, "G + identity = G")
    negated = (nostr_key._GX, (-nostr_key._GY) % nostr_key._P)
    check(nostr_key._point_add(g, negated) is None, "G + (-G) = identity")

    check(nostr_key.decode_pubkey(NPUB) == NPUB_HEX, "npub decodes to the NIP-19 hex")
    check(nostr_key.encode_npub(NPUB_HEX) == NPUB, "hex encodes to the NIP-19 npub")
    check(nostr_key.decode_pubkey(NPUB_HEX) == NPUB_HEX, "hex passes through unchanged")

    # A single flipped character must fail the checksum, not decode to a
    # different-but-plausible key. This is the whole reason we verify it.
    corrupted = NPUB[:-2] + ("aa" if not NPUB.endswith("aa") else "qq")
    try:
        nostr_key.decode_pubkey(corrupted)
        print("FAIL a corrupted npub was accepted", file=sys.stderr)
        return 1
    except ValueError:
        print("ok   a corrupted npub is rejected by the checksum")

    # An nsec must be refused outright, with an explanation.
    nsec = nostr_key.bech32_encode("nsec", nostr_key.convertbits(list(bytes.fromhex(NPUB_HEX)), 8, 5))
    try:
        nostr_key.decode_pubkey(nsec)
        print("FAIL an nsec was accepted as a pubkey", file=sys.stderr)
        return 1
    except ValueError as exc:
        check("PRIVATE" in str(exc), "an nsec is refused with a clear warning")

    # Generated keys must round-trip through derivation and encoding.
    for _ in range(3):
        secret_hex, pubkey_hex = nostr_key.generate_keypair()
        check(len(secret_hex) == 64 and len(pubkey_hex) == 64,
              "generated keys are 64 hex characters")
        check(nostr_key.derive_pubkey(secret_hex) == pubkey_hex,
              "the generated public key is the derived public key")
        check(nostr_key.decode_pubkey(nostr_key.encode_npub(pubkey_hex)) == pubkey_hex,
              "generated key round-trips through npub")

    print("\nall key handling checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
