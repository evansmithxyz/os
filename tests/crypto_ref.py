"""Reference implementations of the kernel's crypto, used by test_tls.py.

Plain Python (standard library only), written straight from the RFCs so the
tests have an oracle that does not share the assembly's bugs:
  ChaCha20 and Poly1305 (RFC 8439), X25519 (RFC 7748), P-256 / P-384 and
  ECDSA (FIPS 186-4), RSA PKCS#1 v1.5 and PSS signing (RFC 8017).
SHA-2 and HMAC come from hashlib / hmac. tools/gen_cryptotest.py uses the
signing functions to make the kernel's fixed verification test vectors.
"""

import hashlib
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


# --- NIST curves and ECDSA (FIPS 186-4) --------------------------------------

class Curve:
    def __init__(self, name, size, p, n, b, gx, gy):
        self.name, self.size, self.p, self.n, self.b, self.g = name, size, p, n, b, (gx, gy)


P256 = Curve(
    "P-256", 32,
    0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF,
    0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551,
    0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B,
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
)
P384 = Curve(
    "P-384", 48,
    int("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFF0000000000000000FFFFFFFF", 16),
    int("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973", 16),
    int("B3312FA7E23EE7E4988E056BE3F82D19181D9C6EFE8141120314088F5013875AC656398D8A2ED19D2A85C8EDD3EC2AEF", 16),
    int("AA87CA22BE8B05378EB1C71EF320AD746E1D3B628BA79B9859F741E082542A385502F25DBF55296C3A545E3872760AB7", 16),
    int("3617DE4A96262C6F5D9E98BF9292DC29F8F41DBD289A147CE9DA3113B5F0B8C00A60B1CE1D7E819D7A431D7C90EA0E5F", 16),
)


def ec_add(c: Curve, P, Q):
    if P is None:
        return Q
    if Q is None:
        return P
    if P[0] == Q[0]:
        if (P[1] + Q[1]) % c.p == 0:
            return None
        lam = (3 * P[0] * P[0] - 3) * pow(2 * P[1], -1, c.p) % c.p
    else:
        lam = (Q[1] - P[1]) * pow(Q[0] - P[0], -1, c.p) % c.p
    x = (lam * lam - P[0] - Q[0]) % c.p
    return x, (lam * (P[0] - x) - P[1]) % c.p


def ec_mul(c: Curve, k: int, P):
    R = None
    for bit in bin(k)[2:]:
        R = ec_add(c, R, R)
        if bit == "1":
            R = ec_add(c, R, P)
    return R


def _der_int(v: int) -> bytes:
    raw = v.to_bytes((v.bit_length() + 8) // 8, "big")     # leading 0 keeps it positive
    return b"\x02" + bytes([len(raw)]) + raw


def _der_seq(body: bytes) -> bytes:
    if len(body) < 0x80:
        return b"\x30" + bytes([len(body)]) + body
    return b"\x30\x81" + bytes([len(body)]) + body


def ecdsa_sign(c: Curve, d: int, digest: bytes, k: int) -> bytes:
    """DER signature with the given nonce k (tests only: never reuse k)."""
    e = int.from_bytes(digest[: c.size], "big") % c.n
    r = ec_mul(c, k, c.g)[0] % c.n
    s = pow(k, -1, c.n) * (e + r * d) % c.n
    return _der_seq(_der_int(r) + _der_int(s))


def ec_public(c: Curve, d: int) -> bytes:
    x, y = ec_mul(c, d, c.g)
    return b"\x04" + x.to_bytes(c.size, "big") + y.to_bytes(c.size, "big")


# --- RSA (RFC 8017) ------------------------------------------------------------

def _is_probable_prime(n: int, rng) -> bool:
    if n < 2:
        return False
    for p in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if n % p == 0:
            return n == p
    d, s = n - 1, 0
    while d % 2 == 0:
        d, s = d // 2, s + 1
    for _ in range(24):
        x = pow(rng.randrange(2, n - 1), d, n)
        if x in (1, n - 1):
            continue
        for _ in range(s - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def rsa_keygen(bits: int, rng, e: int = 65537):
    """(n, e, d) from a seeded random.Random, so the test vectors are stable."""
    while True:
        ps = []
        while len(ps) < 2:
            cand = rng.getrandbits(bits // 2) | (3 << (bits // 2 - 2)) | 1
            if _is_probable_prime(cand, rng) and (cand - 1) % e:
                ps.append(cand)
        n = ps[0] * ps[1]
        if n.bit_length() == bits and ps[0] != ps[1]:
            return n, e, pow(e, -1, (ps[0] - 1) * (ps[1] - 1))


_DIGEST_INFO = {
    "sha256": bytes.fromhex("3031300d060960864801650304020105000420"),
    "sha384": bytes.fromhex("3041300d060960864801650304020205000430"),
    "sha512": bytes.fromhex("3051300d060960864801650304020305000440"),
}


def rsa_sign_pkcs1(n: int, d: int, digest: bytes, hash_name: str) -> bytes:
    k = (n.bit_length() + 7) // 8
    t = _DIGEST_INFO[hash_name] + digest
    em = b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t
    return pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")


def _mgf1(seed: bytes, length: int, hash_name: str) -> bytes:
    out = b""
    counter = 0
    while len(out) < length:
        out += hashlib.new(hash_name, seed + counter.to_bytes(4, "big")).digest()
        counter += 1
    return out[:length]


def rsa_sign_pss(n: int, d: int, digest: bytes, hash_name: str, salt: bytes) -> bytes:
    mod_bits = n.bit_length()
    em_bits = mod_bits - 1
    em_len = (em_bits + 7) // 8
    h = hashlib.new(hash_name, b"\x00" * 8 + digest + salt).digest()
    db = b"\x00" * (em_len - len(salt) - len(h) - 2) + b"\x01" + salt
    masked = bytearray(a ^ b for a, b in zip(db, _mgf1(h, len(db), hash_name)))
    masked[0] &= 0xFF >> (8 * em_len - em_bits)
    em = bytes(masked) + h + b"\xbc"
    k = (mod_bits + 7) // 8
    return pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")


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
