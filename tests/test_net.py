"""Network stack: NIC, ICMP, TCP client (curl) and the guest web server.

QEMU's user-mode network makes the host reachable from the guest as 10.0.2.2,
so these tests run a small HTTP server on the host and fetch from it.
Set AGOS_TEST_INTERNET=1 to also run the DNS test against the real internet.
"""

import http.server
import os
import threading
import time
import unittest
import urllib.request
from functools import partial
from pathlib import Path

from tests.harness import OUTPUT, PROMPT, OSTestCase

HELLO_HTML = "<html><body><h1>Hello from the host</h1><p>served by tests/test_net.py</p></body></html>"

# Shaped like www.google.com: a <head> much longer than the old 16 KB response
# buffer, scripts and styles whose text must not be drawn, entities and divs.
BIG_HTML = (
    "<!doctype html><html><head><title>Big page</title>"
    "<link rel='stylesheet' href='big.css'>"
    "<script>" + "var hidden = 'SCRIPT TEXT MUST NOT SHOW';\n" * 1000 + "</script>"
    "<style>body { color: red }</style></head>"
    "<body><!-- comment > with text --><script>document.write('also hidden')</script>"
    "<div>Big page body</div><p>Fish &amp; chips &lt;3</p></body></html>"
)

# No "</head>" at all: the page must still render instead of coming up blank
NO_HEAD_END_HTML = "<html><head><title>Broken</title><body><p>Still visible</p></body></html>"

# Layout features, then enough lines to scroll (tests/test_gui.py BrowserLayoutTest)
FEATURES_HTML = (
    "<html><head><title>Feature\n   test</title></head><body>\n"
    "<p>Collapsed\n   white    space</p>\n"
    "<p>It&#x27;s &copy 2026 &mdash; caf&eacute; “quoted” ’ &#8364;5</p>\n"
    "<table><tr><td><center>1.</center></td><td><a href='sub/'>Row title</a></td></tr></table>\n"
    + "".join(f"<p>Line {n}</p>\n" for n in range(1, 81))
    + "<p>The end</p></body></html>"
)

# CSS selectors, cascade and @media (tests/test_gui.py). Only SHOWN* may be drawn.
CSS_HTML = """<html><head><style>
.a .b { visibility: hidden }
#x { display: none }
.c > .d { display: none }
.g .d { display: none }
@media print { .e { display: none } }
@media (max-width: 100px) { .f { display: none } }
@media screen and (min-width: 600px) { .h { display: none } }
div.i { display: none } div.i { display: block }
.j { display: none !important } #k { display: block }
.nest { color: red; .inner { color: blue } }
.after-nest { display: none }
.l:first-child { display: none }
.m:not(.n) { display: none }
.m:not(:hover) { color: green }
.sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0) }
.closed { height: 0; overflow: hidden }
</style><link rel="stylesheet" href="extra.css"></head><body>
<div class="after-nest">HIDDEN10</div>
<p><span class="l">HIDDEN11</span> <span class="l">SHOWN0</span></p>
<div class="m">HIDDEN12</div><div class="m n">SHOWNA</div>
<span class="sr">HIDDEN13</span><div class="closed">HIDDEN14</div>
<details><summary>SHOWNB</summary>HIDDEN15</details>
<table><tr><td bgcolor="#ff6600">SHOWNC</td></tr></table>
<div class="a"><div class="b">HIDDEN1</div></div>
<div id="x">HIDDEN2</div>
<div class="c"><span class="d">HIDDEN3</span></div>
<div class="g"><p><span class="d">HIDDEN5</span></p></div>
<div class="e">SHOWN1</div><div class="f">SHOWN2</div>
<div class="h">HIDDEN6</div>
<p style="display:none">HIDDEN4</p>
<div class="i">SHOWN3</div>
<div class="j" id="k">HIDDEN7</div>
<div class="fromsheet">HIDDEN8</div>
<p hidden>HIDDEN9</p>
<p>SHOWN4</p></body></html>"""
EXTRA_CSS = ".fromsheet { display: none }\n"

# A relative link at the top left of the page
LINKS_HTML = "<html><body><a href='sub'>Go to sub</a> <a href='features.html'>Features</a></body></html>"


class HostWebServer:
    """http.server on 127.0.0.1 (reachable from the guest as 10.0.2.2:<port>)."""

    def __init__(self):
        self.root = OUTPUT / "www"
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "hello.html").write_text(HELLO_HTML)
        (self.root / "big.html").write_text(BIG_HTML)
        (self.root / "nohead.html").write_text(NO_HEAD_END_HTML)
        (self.root / "features.html").write_text(FEATURES_HTML, encoding="utf-8")
        (self.root / "links.html").write_text(LINKS_HTML)
        (self.root / "css.html").write_text(CSS_HTML)
        (self.root / "extra.css").write_text(EXTRA_CSS)
        # GET /sub answers "301 Location: /sub/" (http.server adds the slash)
        (self.root / "sub").mkdir(exist_ok=True)
        (self.root / "sub" / "index.html").write_text("<html><body><p>Sub page</p></body></html>")
        handler = partial(_QuietHandler, directory=str(self.root))
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class NetworkTest(OSTestCase):

    def test_ifconfig(self):
        out = self.vm.run("ifconfig")
        self.assertIn("52:54:00:12:34:56", out)
        self.assertIn("IPv4:        10.0.2.15", out)

    def test_ping_gateway(self):
        out = self.vm.run("ping 10.0.2.2", timeout=20)
        self.assertEqual(out.count("64 bytes from 10.0.2.2"), 4, out)
        self.assertNotIn("timed out", out)

    def test_curl_host_server(self):
        with HostWebServer() as web:
            out = self.vm.run(f"curl 10.0.2.2:{web.port}/hello.html", timeout=20)
        self.assertIn("[CONNECTED]", out)
        self.assertIn("HTTP/1.0 200 OK", out)          # headers (first segment)
        self.assertIn("Hello from the host", out)      # body (second segment)
        self.assertLess(out.index("HTTP/1.0 200 OK"), out.index("Hello from the host"))

    def test_curl_bad_port(self):
        self.assertIn("Invalid port", self.vm.run("curl 10.0.2.2 99999"))

    def test_tcplisten_serves_host(self):
        self.vm.send("tcplisten\r")
        self.vm.expect("Listening on port 80")
        body = ""
        for _ in range(20):  # the server loop may need a moment
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self.vm.web_port}/", timeout=5) as resp:
                    body = resp.read().decode()
                break
            except OSError:
                time.sleep(0.25)
        self.assertIn("Antigravity OS", body)
        self.vm.expect("Webpage served successfully")
        self.vm.send("q")
        self.vm.expect("Web server stopped")
        self.vm.expect(PROMPT)

    @unittest.skipUnless(os.environ.get("AGOS_TEST_INTERNET"), "set AGOS_TEST_INTERNET=1")
    def test_dns_real_internet(self):
        out = self.vm.run("dns example.com", timeout=20)
        self.assertRegex(out, r"Address: \d+\.\d+\.\d+\.\d+")


if __name__ == "__main__":
    unittest.main()
