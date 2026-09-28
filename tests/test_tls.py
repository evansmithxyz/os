"""TLS 1.3: the crypto primitives (checked against tests/crypto_ref.py) and
HTTPS against a local Python TLS server.

The server uses the self-signed test certificate in tests/data/. The OS does
not verify certificates yet, so the browser and curl must say so.
Set AGOS_TEST_INTERNET=1 to also fetch https://www.google.com/.
"""

import hashlib
import hmac
import os
import ssl
import unittest
from pathlib import Path

from tests import crypto_ref as ref
from tests.harness import OSTestCase
from tests.test_net import HostWebServer

DATA = Path(__file__).resolve().parent / "data"


class HostTLSServer(HostWebServer):
    """HostWebServer over TLS 1.3 (reachable from the guest as https://10.0.2.2:<port>).
    Records the version and cipher each connection negotiated in `sessions`."""

    def __init__(self):
        super().__init__()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(DATA / "test_server.crt", DATA / "test_server.key")
        self.sessions = []
        httpd = self.httpd
        plain_get_request = httpd.get_request

        def get_request():
            sock, addr = plain_get_request()
            tls = ctx.wrap_socket(sock, server_side=True, do_handshake_on_connect=False)
            try:
                tls.settimeout(10)
                tls.do_handshake()
            except (ssl.SSLError, OSError) as exc:
                self.sessions.append(("failed", repr(exc)))
                tls.close()
                raise
            self.sessions.append((tls.version(), tls.cipher()[0]))
            return tls, addr

        httpd.get_request = get_request


def _parse(out: str) -> dict:
    lines = {}
    for line in out.splitlines():
        label, sep, value = line.partition(": ")
        if sep:
            lines.setdefault(label.strip(), []).append(value.strip().lower())
    return lines


class CryptoTest(OSTestCase):

    def test_cryptotest_matches_reference(self):
        out = _parse(self.vm.run("cryptotest", timeout=30))
        h = bytes.fromhex

        self.assertEqual(out["sha256 abc"], [hashlib.sha256(b"abc").hexdigest()])
        self.assertEqual(out["sha256 200"], [hashlib.sha256(bytes(range(200))).hexdigest()])
        self.assertEqual(out["hmac jefe"],
                         [hmac.new(b"Jefe", b"what do ya want for nothing?", hashlib.sha256).hexdigest()])

        key = bytes(range(32))
        nonce = h("000000090000004a00000000")
        self.assertEqual(out["chacha20 block"], [ref.chacha20_block(key, 1, nonce).hex()])

        poly_key = h("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
        self.assertEqual(out["poly1305"], [ref.poly1305(poly_key, b"Cryptographic Forum Research Group").hex()])

        plain = (b"Ladies and Gentlemen of the class of '99: If I could offer you only one "
                 b"tip for the future, sunscreen would be it.")
        sealed = ref.aead_seal(bytes(range(0x80, 0xA0)), h("070000004041424344454647"),
                               h("50515253c0c1c2c3c4c5c6c7"), plain)
        self.assertEqual(out["aead seal"], [sealed.hex()])
        self.assertEqual(out["aead open"], ["ok"])
        self.assertEqual(out["aead tamper"], ["rejected"])

        scalar = h("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        u = h("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        alice = h("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        bob_pub = h("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        self.assertEqual(out["x25519 rfc"], [ref.x25519(scalar, u).hex()])
        self.assertEqual(out["x25519 base"], [ref.x25519(alice, ref.X25519_BASE).hex()])
        self.assertEqual(out["x25519 shared"], [ref.x25519(alice, bob_pub).hex()])

        first, second = out["random"]
        self.assertEqual(len(first), 32)
        self.assertNotEqual(first, second)


class HttpsTest(OSTestCase):

    def test_curl_https(self):
        with HostTLSServer() as tls:
            out = self.vm.run(f"curl https://10.0.2.2:{tls.port}/hello.html", timeout=30)
        self.assertEqual(tls.sessions, [("TLSv1.3", "TLS_CHACHA20_POLY1305_SHA256")])
        self.assertIn("certificate was NOT verified", out)
        self.assertIn("HTTP/1.0 200 OK", out)
        self.assertIn("Hello from the host", out)
        self.assertLess(out.index("NOT verified"), out.index("Hello from the host"))

    @unittest.skipUnless(os.environ.get("AGOS_TEST_INTERNET"), "set AGOS_TEST_INTERNET=1")
    def test_curl_https_google(self):
        out = self.vm.run("curl https://www.google.com/", timeout=40)
        self.assertIn("certificate was NOT verified", out)
        self.assertRegex(out, r"HTTP/1\.[01] 200 OK")
        self.assertIn("</html>", out.lower())

    def test_browser_https_warns_certificate_not_verified(self):
        with HostTLSServer() as tls:
            self.vm.send(f"browser https://10.0.2.2:{tls.port}/hello.html\r")
            self.vm.expect("gui: started")
            self.vm.expect("tls: handshake done", timeout=30)
            self.vm.expect("browser status: CERT NOT VERIFIED | HTTP/1.0 200 OK | 10.0.2.2")
            self.vm.expect("browser text: Hello from the host served by tests/test_net.py")
        self.vm.screenshot("https_page")

    def test_browser_https_large_page(self):
        """A 44 KB page arrives as several 16 KB records."""
        with HostTLSServer() as tls:
            self.vm.send(f"browser https://10.0.2.2:{tls.port}/big.html\r")
            self.vm.expect("browser status: CERT NOT VERIFIED | HTTP/1.0 200 OK", timeout=30)
            self.vm.expect("browser text: Big page body Fish & chips <3")

    def test_browser_https_relative_redirect_stays_https(self):
        with HostTLSServer() as tls:
            self.vm.send(f"browser https://10.0.2.2:{tls.port}/sub\r")
            self.vm.expect(f"browser: redirect -> https://10.0.2.2:{tls.port}/sub/", timeout=30)
            self.vm.expect("browser status: CERT NOT VERIFIED | HTTP/1.0 200 OK", timeout=30)
            self.vm.expect("browser text: Sub page")
        self.assertEqual(set(tls.sessions), {("TLSv1.3", "TLS_CHACHA20_POLY1305_SHA256")})
        self.assertEqual(len(tls.sessions), 2)

    def test_browser_tls_failure_page(self):
        with HostWebServer() as web:
            self.vm.send(f"browser https://10.0.2.2:{web.port}/hello.html\r")
            self.vm.expect("browser: CyberSurf - Secure Connection Failed", timeout=30)
            self.vm.expect("browser status: Error: TLS malformed record")

    @unittest.skipUnless(os.environ.get("AGOS_TEST_INTERNET"), "set AGOS_TEST_INTERNET=1")
    def test_browser_https_google(self):
        self.vm.send("browser https://www.google.com/\r")
        self.vm.expect("browser status: CERT NOT VERIFIED | HTTP/1.0 200 OK | www.google.com", timeout=40)
        line = self.vm.expect(r"browser text: [^\r\n]*\r?\n", regex=True)
        self.assertRegex(line, r"browser text: \S")
        self.vm.screenshot("google_https")

    def test_curl_https_to_plain_http_server_fails_cleanly(self):
        with HostWebServer() as web:
            out = self.vm.run(f"curl https://10.0.2.2:{web.port}/hello.html", timeout=30)
        self.assertIn("[TLS] Handshake failed", out)
        self.assertNotIn("Hello from the host", out)


if __name__ == "__main__":
    unittest.main()
