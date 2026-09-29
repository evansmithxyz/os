"""TLS 1.3: the crypto primitives (checked against tests/crypto_ref.py) and
HTTPS against a local Python TLS server.

Certificates come from the test PKI in tests/data/pki (tests/data/make_pki.sh):
the OS disk gets its two roots as localca.der, so the OS trusts the "good"
servers and must reject the expired, wrong-host and self-signed ones.
tests/data/test_server.* is a self-signed certificate nobody trusts.
Set AGOS_TEST_INTERNET=1 to also verify real sites (Google, GitHub, ...).
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
PKI = DATA / "pki"
LOCAL_CA = (PKI / "localca.der").read_bytes()


class HostTLSServer(HostWebServer):
    """HostWebServer over TLS 1.3 (reachable from the guest as https://10.0.2.2:<port>).
    `name` picks the certificate in tests/data/pki (srv_ec, srv_rsa, srv_expired,
    srv_wronghost) or "selfsigned". Records each connection's version and cipher
    in `sessions`."""

    def __init__(self, name: str = "srv_ec"):
        super().__init__()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        if name == "selfsigned":
            ctx.load_cert_chain(DATA / "test_server.crt", DATA / "test_server.key")
        elif name == "srv_rsa":
            ctx.load_cert_chain(PKI / "srv_rsa_chain.crt", PKI / "srv_rsa.key")
        else:
            ctx.load_cert_chain(PKI / f"{name}.crt", PKI / f"{name}.key")
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

        self.assertEqual(out["sha384 abc"], [hashlib.sha384(b"abc").hexdigest()])
        self.assertEqual(out["sha512 200"], [hashlib.sha512(bytes(range(200))).hexdigest()])

        # kernel/apps/shell/cryptotest_vectors.inc (tools/gen_cryptotest.py)
        for name in ("rsa2048 pkcs1 sha256", "rsa2048 pss sha256", "rsa4096 pkcs1 sha384",
                     "ecdsa p256 sha256", "ecdsa p384 sha384", "ecdsa p256 sha384"):
            self.assertEqual(out.get(name), ["ok"], name)
            self.assertEqual(out.get(f"{name} tampered"), ["rejected"], name)


CHACHA13 = ("TLSv1.3", "TLS_CHACHA20_POLY1305_SHA256")


class HttpsTest(OSTestCase):
    disk_files = {"localca.der": LOCAL_CA}

    def curl(self, server: str, path: str = "/hello.html", flags: str = "") -> str:
        with HostTLSServer(server) as tls:
            out = self.vm.run(f"curl {flags}https://10.0.2.2:{tls.port}{path}", timeout=40)
        self.sessions = tls.sessions
        return out

    # --- trusted servers ---------------------------------------------------------
    def test_curl_verifies_ecdsa_certificate(self):
        """P-256 server key (ECDSA CertificateVerify), signed by the P-384 root with SHA-384."""
        out = self.curl("srv_ec")
        self.assertEqual(self.sessions, [CHACHA13])
        self.assertIn("Certificate verified for 10.0.2.2", out)
        self.assertIn("HTTP/1.0 200 OK", out)
        self.assertIn("Hello from the host", out)
        log = self.vm.output
        self.assertIn("x509: server certificate 10.0.2.2", log)
        self.assertIn("x509: trusted root Antigravity Test Root P-384", log)

    def test_curl_verifies_rsa_chain(self):
        """RSA-2048 server (RSA-PSS CertificateVerify) -> RSA intermediate -> RSA-4096 root."""
        out = self.curl("srv_rsa")
        self.assertIn("Certificate verified for 10.0.2.2", out)
        self.assertIn("Hello from the host", out)
        log = self.vm.output
        self.assertIn("x509: signed by Antigravity Test Intermediate RSA", log)
        self.assertIn("x509: trusted root Antigravity Test Root RSA-4096", log)

    # --- servers that must be rejected -------------------------------------------
    def assert_rejected(self, out: str, reason: str):
        self.assertIn(f"[TLS] Handshake failed: {reason}", out)
        self.assertNotIn("Hello from the host", out)

    def test_curl_rejects_self_signed(self):
        self.assert_rejected(self.curl("selfsigned"), "certificate is not from a trusted authority")

    def test_curl_rejects_expired(self):
        self.assert_rejected(self.curl("srv_expired"), "certificate has expired")

    def test_curl_rejects_wrong_host(self):
        self.assert_rejected(self.curl("srv_wronghost"), "certificate is not for this host name")

    def test_curl_insecure_skips_the_checks(self):
        out = self.curl("selfsigned", flags="-k ")
        self.assertIn("-k given, the certificate was NOT verified", out)
        self.assertIn("Hello from the host", out)

    def test_curl_https_to_plain_http_server_fails_cleanly(self):
        with HostWebServer() as web:
            out = self.vm.run(f"curl https://10.0.2.2:{web.port}/hello.html", timeout=30)
        self.assert_rejected(out, "malformed record")

    # --- the browser -----------------------------------------------------------------
    def test_browser_https_verified(self):
        with HostTLSServer("srv_rsa") as tls:
            self.vm.send(f"browser https://10.0.2.2:{tls.port}/hello.html\r")
            self.vm.expect("gui: started")
            self.vm.expect("tls: certificate verified for 10.0.2.2", timeout=30)
            self.vm.expect("browser status: HTTP/1.0 200 OK | 10.0.2.2")
            self.vm.expect("browser text: Hello from the host served by tests/test_net.py")
        self.vm.screenshot("https_page")

    def test_browser_https_large_page(self):
        """A 44 KB page arrives as several 16 KB records."""
        with HostTLSServer() as tls:
            self.vm.send(f"browser https://10.0.2.2:{tls.port}/big.html\r")
            self.vm.expect("browser status: HTTP/1.0 200 OK", timeout=30)
            self.vm.expect("browser text: Big page body Fish & chips <3")

    def test_browser_https_relative_redirect_stays_https(self):
        with HostTLSServer() as tls:
            self.vm.send(f"browser https://10.0.2.2:{tls.port}/sub\r")
            self.vm.expect(f"browser: redirect -> https://10.0.2.2:{tls.port}/sub/", timeout=30)
            self.vm.expect("browser status: HTTP/1.0 200 OK", timeout=30)
            self.vm.expect("browser text: Sub page")
        self.assertEqual(tls.sessions, [CHACHA13, CHACHA13])

    def test_browser_rejects_expired_certificate(self):
        with HostTLSServer("srv_expired") as tls:
            self.vm.send(f"browser https://10.0.2.2:{tls.port}/hello.html\r")
            self.vm.expect("browser: CyberSurf - Secure Connection Failed", timeout=30)
            self.vm.expect("browser status: Error: TLS certificate has expired")

    def test_browser_tls_failure_page(self):
        with HostWebServer() as web:
            self.vm.send(f"browser https://10.0.2.2:{web.port}/hello.html\r")
            self.vm.expect("browser: CyberSurf - Secure Connection Failed", timeout=30)
            self.vm.expect("browser status: Error: TLS malformed record")


class HttpsNoLocalRootsTest(OSTestCase):
    """Without localca.der the test roots are not trusted."""

    def test_test_pki_is_not_trusted_by_default(self):
        with HostTLSServer("srv_ec") as tls:
            out = self.vm.run(f"curl https://10.0.2.2:{tls.port}/hello.html", timeout=30)
        self.assertIn("[TLS] Handshake failed: certificate is not from a trusted authority", out)


@unittest.skipUnless(os.environ.get("AGOS_TEST_INTERNET"), "set AGOS_TEST_INTERNET=1")
class HttpsInternetTest(OSTestCase):
    """Real sites, with the compiled-in Mozilla roots. Between them they need ECDSA
    P-256/P-384, RSA PKCS#1 and RSA-PSS, SHA-256/384 and cross-signed chains.
    (No shared VM: the browser test leaves the browser holding the keyboard.)"""

    def test_real_sites_verify(self):
        for host in ("www.google.com", "github.com", "en.wikipedia.org", "example.com",
                     "www.amazon.com", "www.microsoft.com", "letsencrypt.org"):
            with self.subTest(host=host):
                out = self.vm.run(f"curl https://{host}/", timeout=60)
                self.assertIn(f"Certificate verified for {host}", out)
                self.assertRegex(out, r"HTTP/1\.[01] \d\d\d")

    def test_browser_https_google(self):
        self.vm.send("browser https://www.google.com/\r")
        self.vm.expect("browser status: HTTP/1.0 200 OK | www.google.com", timeout=40)
        line = self.vm.expect(r"browser text: [^\r\n]*\r?\n", regex=True)
        self.assertRegex(line, r"browser text: \S")
        self.vm.screenshot("google_https")


if __name__ == "__main__":
    unittest.main()
