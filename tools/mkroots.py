#!/usr/bin/env python3
"""Build kernel/data/roots.der, the TLS trust store compiled into the kernel.

The input is a PEM bundle of root certificates, normally the Mozilla set as
shipped by Debian/Ubuntu's ca-certificates package:

    python tools/mkroots.py                       # /etc/ssl/certs/ca-certificates.crt
    python tools/mkroots.py path/to/bundle.pem

The output is the DER certificates back to back (each one is a self-delimiting
SEQUENCE), plus kernel/data/roots.txt listing what went in. Commit both; rerun
this when the roots should be refreshed. Extra roots for your own servers go
in the AFS file localca.der instead (see README), not here.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "kernel" / "data" / "roots.der"
LIST = ROOT / "kernel" / "data" / "roots.txt"
DEFAULT_BUNDLE = Path("/etc/ssl/certs/ca-certificates.crt")
MAX_BYTES = 256 * 1024          # it has to fit in the kernel slot with the code


def pem_blocks(text: str) -> list[bytes]:
    return [base64.b64decode(m) for m in
            re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S)]


def _tlv(data: bytes, pos: int) -> tuple[int, int, int]:
    """(tag, content start, content end) of the DER element at pos."""
    tag, first = data[pos], data[pos + 1]
    pos += 2
    if first < 0x80:
        length = first
    else:
        count = first & 0x7F
        length = int.from_bytes(data[pos:pos + count], "big")
        pos += count
    return tag, pos, pos + length


def subject_cn(der: bytes) -> str:
    """Best-effort common name (or organisation) of the subject, for roots.txt."""
    _, c, _ = _tlv(der, 0)                     # Certificate
    _, t, t_end = _tlv(der, c)                 # tbsCertificate
    pos = t
    fields = []
    while pos < t_end:
        tag, s, e = _tlv(der, pos)
        fields.append((tag, s, e, pos))
        pos = e
    if fields[0][0] == 0xA0:
        fields = fields[1:]
    _, s, e, _ = fields[4]                     # serial, sigalg, issuer, validity, subject
    name = der[s:e]
    for oid in (b"\x06\x03\x55\x04\x03", b"\x06\x03\x55\x04\x0a"):
        i = name.find(oid)
        if i >= 0:
            _, vs, ve = _tlv(name, i + len(oid))
            return name[vs:ve].decode("utf-8", "replace")
    return "?"


def main(argv: list[str]) -> int:
    bundle = Path(argv[1]) if len(argv) > 1 else DEFAULT_BUNDLE
    certs = pem_blocks(bundle.read_text())
    if not certs:
        print(f"no certificates in {bundle}", file=sys.stderr)
        return 1
    blob = b"".join(certs)
    if len(blob) > MAX_BYTES:
        print(f"{len(blob)} bytes is more than {MAX_BYTES}", file=sys.stderr)
        return 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(blob)
    lines = [
        f"# {len(certs)} root certificates in roots.der ({len(blob)} bytes)",
        f"# from {bundle} on {datetime.date.today().isoformat()}, sha256 {hashlib.sha256(blob).hexdigest()}",
        "",
    ] + sorted(subject_cn(c) for c in certs)
    LIST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(certs)} roots, {len(blob)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
