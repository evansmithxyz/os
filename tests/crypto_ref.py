"""Reference implementations of the kernel's crypto, used by test_tls.py.

Plain Python (standard library only), written straight from the RFCs so the
tests have an oracle that does not share the assembly's bugs:
  ChaCha20 and Poly1305 (RFC 8439), X25519 (RFC 7748).
SHA-256 and HMAC come from hashlib / hmac.
"""

import struct

# --- ChaCha20 (RFC 8439 section 2.3) ----------------------------------------

def _rotl32(v: int, n: int) -> int:
    return ((v << n) & 0xFFFFFFFF) | (v >> (32 - n))


def _quarter_round(x: list, a: int, b: int, c: int, d: int) -> None:
    x[a] = (x[a] + x[b]) & 0xFFFFFFFF; x[d] = _rotl32(x[d] ^ x[a], 16)
    x[c] = (x[c] + x[d]) & 0xFFFFFFFF; x[b] = _rotl32(x[b] ^ x[c], 12)
    x[a] = (x[a] + x[b]) & 0xFFFFFFFF; x[d] = _rotl32(x[d] ^ x[a], 8)
    x[c] = (x[c] + x[d]) & 0xFFFFFFFF; x[b] = _rotl32(x[b] ^ x[c], 7)


def chacha20_block(key: bytes, counter: int, nonce: bytes) -> bytes:
    state = [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574]
    state += list(struct.unpack("<8L", key)) + [counter] + list(struct.unpack("<3L", nonce))
    x = state[:]
    for _ in range(10):
        _quarter_round(x, 0, 4, 8, 12); _quarter_round(x, 1, 5, 9, 13)
        _quarter_round(x, 2, 6, 10, 14); _quarter_round(x, 3, 7, 11, 15)
        _quarter_round(x, 0, 5, 10, 15); _quarter_round(x, 1, 6, 11, 12)
        _quarter_round(x, 2, 7, 8, 13); _quarter_round(x, 3, 4, 9, 14)
    return struct.pack("<16L", *((x[i] + state[i]) & 0xFFFFFFFF for i in range(16)))


def chacha20_xor(key: bytes, counter: int, nonce: bytes, data: bytes) -> bytes:
    out = bytearray()
    for i in range(0, len(data), 64):
        block = chacha20_block(key, counter + i // 64, nonce)
        out += bytes(a ^ b for a, b in zip(data[i:i + 64], block))
    return bytes(out)


# --- Poly1305 (RFC 8439 section 2.5) ------------------------------------------

def poly1305(key: bytes, msg: bytes) -> bytes:
    r = int.from_bytes(key[:16], "little") & 0x0FFFFFFC0FFFFFFC0FFFFFFC0FFFFFFF
    s = int.from_bytes(key[16:], "little")
    p = (1 << 130) - 5
    acc = 0
    for i in range(0, len(msg), 16):
        n = int.from_bytes(msg[i:i + 16] + b"\x01", "little")
        acc = (acc + n) * r % p
    return ((acc + s) & ((1 << 128) - 1)).to_bytes(16, "little")


def aead_seal(key: bytes, nonce: bytes, aad: bytes, plaintext: bytes) -> bytes:
    """ChaCha20-Poly1305 (RFC 8439 section 2.8): ciphertext || tag."""
    otk = chacha20_block(key, 0, nonce)[:32]
    ct = chacha20_xor(key, 1, nonce, plaintext)
    pad = lambda b: b"\x00" * (-len(b) % 16)
    mac = aad + pad(aad) + ct + pad(ct) + struct.pack("<QQ", len(aad), len(ct))
    return ct + poly1305(otk, mac)


# --- X25519 (RFC 7748 section 5) ---------------------------------------------

_P = 2**255 - 19
_A24 = 121665


def x25519(scalar: bytes, u: bytes) -> bytes:
    k = bytearray(scalar)
    k[0] &= 248; k[31] &= 127; k[31] |= 64
    k = int.from_bytes(k, "little")
    x1 = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        bit = (k >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a = (x2 + z2) % _P; aa = a * a % _P
        b = (x2 - z2) % _P; bb = b * b % _P
        e = (aa - bb) % _P
        c = (x3 + z3) % _P; d = (x3 - z3) % _P
        da = d * a % _P; cb = c * b % _P
        x3 = (da + cb) ** 2 % _P
        z3 = x1 * (da - cb) ** 2 % _P
        x2 = aa * bb % _P
        z2 = e * (aa + _A24 * e) % _P
    if swap:
        x2, x3, z2, z3 = x3, x2, z3, z2
    return (x2 * pow(z2, _P - 2, _P) % _P).to_bytes(32, "little")


X25519_BASE = (9).to_bytes(32, "little")


def _self_check() -> None:
    """Known answers from RFC 7748 and RFC 8439."""
    h = bytes.fromhex
    assert x25519(h("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
                  h("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")) == \
        h("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
    alice = h("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    bob = h("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    assert x25519(alice, X25519_BASE) == h("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    assert x25519(bob, X25519_BASE) == h("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
    assert x25519(alice, x25519(bob, X25519_BASE)) == \
        h("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    assert poly1305(h("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"),
                    b"Cryptographic Forum Research Group") == h("a8061dc1305136c6c22b8baf0c0127a9")


_self_check()
