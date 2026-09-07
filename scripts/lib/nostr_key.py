#!/usr/bin/env python3
"""Nostr key handling for buzzctl: bech32 <-> hex, and keypair generation.

Two jobs, both small and both worth doing correctly:

  --decode   accept an npub or a hex pubkey and emit 64-char lowercase hex.
             The bech32 checksum is verified, so a mistyped npub is rejected
             rather than silently added to the relay roster as a key nobody
             holds. That failure mode is invisible until the person cannot log
             in, and confusing when it happens.

  --generate mint a secp256k1 keypair. Used for agent identities, which the
             platform owns; human keys should be generated on the human's own
             device and never transit this tool. Implemented against the
             standard library alone, so it works on any machine that can run
             this repository at all.

BIP-340 x-only public keys: Nostr identifies a key by the 32-byte x coordinate
alone, so the leading 02/03 parity byte of the compressed SEC1 form is dropped.
"""

from __future__ import annotations

import argparse
import re
import secrets
import sys

BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BECH32_GENERATOR = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]

HEX64 = re.compile(r"^[0-9a-f]{64}$")


def bech32_polymod(values: list[int]) -> int:
    chk = 1
    for value in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ value
        for i in range(5):
            chk ^= BECH32_GENERATOR[i] if ((top >> i) & 1) else 0
    return chk


def bech32_hrp_expand(hrp: str) -> list[int]:
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]


def bech32_decode(value: str) -> tuple[str, list[int]]:
    if value != value.lower() and value != value.upper():
        raise ValueError("mixed-case bech32 string")
    value = value.lower()

    position = value.rfind("1")
    if position < 1 or position + 7 > len(value) or len(value) > 1000:
        raise ValueError("malformed bech32 string")

    hrp = value[:position]
    try:
        data = [BECH32_CHARSET.index(c) for c in value[position + 1:]]
    except ValueError as exc:
        raise ValueError("bech32 string contains an invalid character") from exc

    if bech32_polymod(bech32_hrp_expand(hrp) + data) != 1:
        raise ValueError(
            "bech32 checksum failed — the key was mistyped or truncated"
        )
    return hrp, data[:-6]


def convertbits(data: list[int], frm: int, to: int, pad: bool = True) -> list[int]:
    acc = 0
    bits = 0
    result: list[int] = []
    maxv = (1 << to) - 1
    for value in data:
        if value < 0 or (value >> frm):
            raise ValueError("invalid value in bit conversion")
        acc = (acc << frm) | value
        bits += frm
        while bits >= to:
            bits -= to
            result.append((acc >> bits) & maxv)
    if pad:
        if bits:
            result.append((acc << (to - bits)) & maxv)
    elif bits >= frm or ((acc << (to - bits)) & maxv):
        raise ValueError("invalid padding in bit conversion")
    return result


def decode_pubkey(value: str) -> str:
    value = value.strip()

    if HEX64.match(value.lower()):
        return value.lower()

    if value.lower().startswith(("npub1", "nsec1")):
        hrp, data = bech32_decode(value)
        if hrp == "nsec":
            raise ValueError(
                "that is a PRIVATE key (nsec). Never paste a private key into "
                "this tool or share it with an operator — send the npub instead."
            )
        if hrp != "npub":
            raise ValueError(f"expected an npub, got a {hrp}")
        decoded = convertbits(data, 5, 8, False)
        if len(decoded) != 32:
            raise ValueError(f"npub decoded to {len(decoded)} bytes, expected 32")
        return bytes(decoded).hex()

    raise ValueError(
        f"{value!r} is neither a 64-character hex pubkey nor an npub1... string"
    )


def bech32_encode(hrp: str, data: list[int]) -> str:
    combined = data + bech32_create_checksum(hrp, data)
    return hrp + "1" + "".join(BECH32_CHARSET[d] for d in combined)


def bech32_create_checksum(hrp: str, data: list[int]) -> list[int]:
    values = bech32_hrp_expand(hrp) + data
    polymod = bech32_polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def encode_npub(hex_pubkey: str) -> str:
    return bech32_encode("npub", convertbits(list(bytes.fromhex(hex_pubkey)), 8, 5))


# secp256k1 domain parameters (SEC 2, section 2.4.1).
_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
_GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
_GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


def _point_add(p: tuple[int, int] | None, q: tuple[int, int] | None):
    """Add two points on secp256k1 in affine coordinates. None is the identity."""
    if p is None:
        return q
    if q is None:
        return p

    px, py = p
    qx, qy = q

    if px == qx and (py + qy) % _P == 0:
        return None

    if p == q:
        # Tangent: lambda = 3x^2 / 2y  (a = 0 for this curve).
        lam = (3 * px * px) * pow(2 * py, _P - 2, _P) % _P
    else:
        lam = (qy - py) * pow(qx - px, _P - 2, _P) % _P

    rx = (lam * lam - px - qx) % _P
    ry = (lam * (px - rx) - py) % _P
    return rx, ry


def _scalar_mult(k: int, point: tuple[int, int]):
    """Double-and-add.

    This derives a PUBLIC key from a secret scalar, offline, once. It is not
    constant time -- Python cannot be -- and it deliberately performs no
    signing. Keeping key generation dependency-free matters more here than a
    side-channel property that has no channel: nothing observes this loop but
    the operator's own terminal. Signing always happens in the relay and the
    clients, in Rust, never here.
    """
    result = None
    addend = point
    while k:
        if k & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        k >>= 1
    return result


def generate_keypair() -> tuple[str, str]:
    """Mint a secp256k1 keypair and return (secret_hex, xonly_pubkey_hex)."""
    # Rejection sampling against the curve order. Reducing a random integer
    # modulo n would bias the low end of the range; for a permanent identity
    # that bias is not worth accepting, however small.
    while True:
        candidate = secrets.randbits(256)
        if 1 <= candidate < _N:
            break

    point = _scalar_mult(candidate, (_GX, _GY))
    assert point is not None  # unreachable for 1 <= k < n
    x, _y = point
    # BIP-340 x-only: Nostr identifies a key by the x coordinate alone, so the
    # 02/03 parity byte of the compressed SEC1 encoding is dropped.
    return f"{candidate:064x}", f"{x:064x}"


def derive_pubkey(secret_hex: str) -> str:
    """Public half of a known secret. Used to check a stored key still matches."""
    secret = int(secret_hex, 16)
    if not 1 <= secret < _N:
        raise ValueError("secret key is out of range for secp256k1")
    point = _scalar_mult(secret, (_GX, _GY))
    assert point is not None
    return f"{point[0]:064x}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--decode", metavar="KEY", help="npub or hex -> hex")
    group.add_argument("--encode", metavar="HEX", help="hex -> npub")
    group.add_argument("--generate", action="store_true", help="mint a new keypair")
    parser.add_argument("--format", choices=["plain", "json"], default="plain")
    args = parser.parse_args()

    try:
        if args.decode:
            print(decode_pubkey(args.decode))
            return 0

        if args.encode:
            hex_key = args.encode.strip().lower()
            if not HEX64.match(hex_key):
                raise ValueError("expected a 64-character lowercase hex pubkey")
            print(encode_npub(hex_key))
            return 0

        secret_hex, pubkey_hex = generate_keypair()
        if args.format == "json":
            import json
            print(json.dumps({
                "secret_hex": secret_hex,
                "pubkey_hex": pubkey_hex,
                "npub": encode_npub(pubkey_hex),
            }))
        else:
            print(f"secret_hex {secret_hex}")
            print(f"pubkey_hex {pubkey_hex}")
            print(f"npub       {encode_npub(pubkey_hex)}")
        return 0

    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
