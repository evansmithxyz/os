"""Network stack: NIC, ICMP, TCP client (curl) and the guest web server.

QEMU's user-mode network makes the host reachable from the guest as 10.0.2.2,
so these tests run a small HTTP server on the host and fetch from it.
Set AGOS_TEST_INTERNET=1 to also run the DNS test against the real internet.
"""

import gzip
import http.server
import os
import zlib
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
    "<body><!-- comment > with text --><script>var alsoHidden = 'also hidden'</script>"
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

# Page scripts and the DOM (tests/test_gui.py): console.log goes to "[klog] js: ..."
JS_HTML = """<html><head><title>JS test</title>
<script>
console.log('head', typeof document, document.readyState, document.body);
var steps = [];
document.addEventListener('DOMContentLoaded', function () { steps.push('ready') });
window.onload = function () { console.log('loaded', steps.join(), document.getElementById('out').textContent) };
</script></head>
<body>
<p id="out">OLD TEXT</p>
<ul id="list"><li class="a">one</li><li class="b">two</li></ul>
<div id="box" style="color: red">box</div>
<script>
var out = document.getElementById('out');
out.textContent = 'NEW & <ok>';
var li = document.createElement('li');
li.className = 'c';
li.appendChild(document.createTextNode('three'));
document.getElementById('list').appendChild(li);
console.log('items', document.querySelectorAll('#list li').length, document.querySelector('ul .b').textContent);
console.log('html', document.getElementById('list').innerHTML);
document.write('<p id="written">WRITTEN</p>');
var box = document.getElementById('box');
box.style.backgroundColor = 'blue';
console.log('style', box.getAttribute('style'), box.style.color);
box.classList.add('x'); box.classList.toggle('y'); box.classList.remove('x');
console.log('class', box.className, box.classList.contains('y'), box.classList.contains('x'));
console.log('tree', out.parentNode.tagName, out.nextElementSibling.id, out.nextSibling.nodeType);
</script>
<script src="extra.js"></script>
<script>this is not javascript</script>
<script>console.log('after an error', document.getElementById('written').tagName)</script>
</body></html>"""
EXTRA_JS = "console.log('external', document.title, location.pathname);\n"

# The web APIs of step 7 (kernel/js/dom.js): classes, fragments, selectors the
# native engine does not know, events, storage, and a script that adds a script
MODERN_HTML = """<html><head><title>Modern</title></head><body>
<ul id="list"><li class="a" data-id="1">one</li><li data-id="2">two</li></ul>
<p id="c">a<!-- note -->b</p>
<script id="first">
var c = document.getElementById('c');
console.log('comments', c.childNodes.length, c.childNodes[1].nodeType, c.childNodes[1].data, c.textContent, c.innerHTML);
var list = document.getElementById('list');
console.log('classes', list instanceof HTMLUListElement, list instanceof HTMLElement, list instanceof Node,
    list.firstChild instanceof HTMLLIElement, document instanceof Document, Object.prototype.toString.call(list));
var f = document.createDocumentFragment(); f.append('x', document.createElement('b')); list.after(f);
list.insertAdjacentHTML('beforeend', '<li data-id="3">three</li>');
console.log('dom', list.children.length, list.lastElementChild.dataset.id, document.querySelectorAll('li[data-id]').length,
    document.querySelector('li:nth-child(2)').textContent, list.querySelector(':scope > li:not(.a)').textContent);
var hits = []; list.addEventListener('ping', function (e) { hits.push(e.detail) }, { once: true });
list.dispatchEvent(new CustomEvent('ping', { detail: 7 })); list.dispatchEvent(new CustomEvent('ping', { detail: 8 }));
localStorage.setItem('k', 'v');
console.log('events', hits.join(), localStorage.getItem('k'), matchMedia('(min-width: 100px)').matches,
    getComputedStyle(list).display, typeof MutationObserver, document.currentScript.id);
var s = document.createElement('script'); s.src = 'modern-extra.js';
s.onload = function () { console.log('loaded', window.extraLoaded) }; document.head.appendChild(s);
</script></body></html>"""
MODERN_EXTRA_JS = "window.extraLoaded = document.currentScript.src.split('/').pop();\n"

# More of the DOM: tree changes, queries, styles, window
DOM_HTML = """<html><head><title>DOM</title></head><body>
<div id="nav" onclick="location.href = 'hello.html'">GO TO HELLO</div>
<div id="top">TOP</div>
<div id="host"></div>
<p class="note first">N1</p><p class="note">N2</p><p class="other">N3</p>
<div id="hideme">VISIBLE UNTIL HIDDEN</div>
<script>
var host = document.getElementById('host');
host.innerHTML = '<ul><li id="i1">one</li><li id="i3">three</li></ul><span>tail &amp; end</span>';
var two = document.createElement('li'); two.id = 'i2'; two.textContent = 'two';
host.querySelector('ul').insertBefore(two, document.getElementById('i3'));
var items = host.getElementsByTagName('li');
var ids = []; for (var i = 0; i < items.length; i++) ids.push(items[i].id);
console.log('ids', ids.join(), host.children.length, host.firstChild.tagName, host.lastChild.textContent);
var copy = host.querySelector('ul').cloneNode(true);
console.log('clone', copy.children.length, copy.parentNode, copy.firstChild.textContent);
var three = document.getElementById('i3');
host.querySelector('ul').replaceChild(document.createTextNode('3!'), three);
console.log('after replace', host.querySelector('ul').textContent, document.getElementById('i3'));
console.log('notes', document.getElementsByClassName('note').length, document.getElementsByClassName('note first').length);
console.log('closest', two.closest('div').id, two.matches('li#i2'), two.matches('p'));
document.body.removeChild(document.getElementById('top'));
document.getElementById('hideme').style.display = 'none';
console.log('html', host.innerHTML);
function early() { console.log('never') }
window.addEventListener('load', early);
window.removeEventListener('load', early);
window.addEventListener('load', function () { console.log('window load', document.readyState) });
alert('hello ' + document.title);
</script>
</body></html>"""

# Click handlers: the first line of the page is the thing to click
CLICK_HTML = """<html><body>
<div id="big" onclick="this.textContent = 'CLICKED ' + (++window.clicks)">PRESS HERE</div>
<p><a id="go" href="hello.html">a link that a handler cancels</a></p>
<script>
window.clicks = 0;
document.getElementById('big').addEventListener('click', function (e) {
    console.log('listener', e.type, e.target.id, e.currentTarget.id);
});
document.body.addEventListener('click', function (e) { console.log('bubbled to body', e.target.id) });
document.getElementById('go').onclick = function (e) { e.preventDefault(); console.log('link cancelled') };
</script>
</body></html>"""

# Garbage collection on a page: text and element objects only the DOM refers to
GC_HTML = """<html><body>
<div id="out"></div>
<script>
var out = document.getElementById('out');
for (var i = 0; i < 5; i++) {
    var p = document.createElement('p');
    p.textContent = ['GC', i, 'TEXT'].join('-');    // a string nothing else keeps
    p.tag = {n: i};                                 // on the element's object
    out.appendChild(p);
}
p = null;
out = null;
var junk;
for (var k = 0; k < 100000; k++) junk = {k: k, s: 'garbage ' + k, a: [k, k]};
var ps = document.getElementsByTagName('p');
var tags = [];
for (var i = 0; i < ps.length; i++) tags.push(ps[i].tag.n);
console.log('after gc', tags.join(), ps[4].textContent);
</script>
</body></html>"""

# Timers, promises, async/await and fetch on a page
ASYNC_HTML = """<html><body>
<p id="t">WAITING</p>
<p id="f">NOT FETCHED</p>
<script>
console.log('sync');
Promise.resolve().then(() => console.log('microtask'));
setTimeout(() => { document.getElementById('t').textContent = 'TIMER FIRED'; console.log('timeout') }, 300);
(async () => {
    const r = await fetch('data.json');
    const d = await r.json();
    document.getElementById('f').textContent = 'FETCHED ' + d.name;
    console.log('fetched', r.status, d.list.length);
})();
var frames = 0;
requestAnimationFrame(function f(t) { if (++frames < 3) requestAnimationFrame(f); else console.log('frames', frames) });
var n = 0;
var iv = setInterval(() => { if (++n === 3) { clearInterval(iv); console.log('interval', n) } }, 50);
var x = new XMLHttpRequest();
x.onload = () => console.log('xhr', x.status, x.responseText.length);
x.open('GET', 'data.json');
x.send();
</script>
</body></html>"""
DATA_JSON = '{"name": "ag", "list": [1, 2, 3]}'

# Form controls (kernel/web/forms.asm): line 1 two text fields, line 2 a check
# box, line 3 a textarea, a <select> and the buttons
FORM_HTML = """<html><head><title>Form</title></head><body>
<form id="f" action="formdone.html"><input id="q" name="q" size="12"> <input name="q2" placeholder="HINT"><br>
<input id="c" type="checkbox" name="c" value="yes"> tick<br>
<input type="hidden" name="h" value="x&amp;y"><textarea id="t" name="t" rows="1">old</textarea>
<select id="s" name="s"><option value="1">one</option><option value="2" selected>two</option><option>three</option></select>
<input type="submit" name="go" value="Go!"> <input type="submit" name="other" value="Other">
<input type="checkbox" name="d" checked disabled></form>
<script>
var q = document.getElementById('q'), c = document.getElementById('c');
document.getElementById('t').value = 'a b\\nc';
q.addEventListener('input', function () { console.log('input', q.value) });
c.addEventListener('change', function () { console.log('change', c.checked) });
document.getElementById('f').addEventListener('submit', function (e) {
    console.log('submit', JSON.stringify(q.value), JSON.stringify(document.getElementById('t').value), document.getElementById('s').value);
});
console.log('form ready', JSON.stringify(document.getElementById('t').value), c.checked);
</script>
</body></html>"""


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
        (self.root / "js.html").write_text(JS_HTML)
        (self.root / "extra.js").write_text(EXTRA_JS)
        (self.root / "click.html").write_text(CLICK_HTML)
        (self.root / "dom.html").write_text(DOM_HTML)
        (self.root / "gc.html").write_text(GC_HTML)
        (self.root / "async.html").write_text(ASYNC_HTML)
        (self.root / "data.json").write_text(DATA_JSON)
        (self.root / "modern.html").write_text(MODERN_HTML)
        (self.root / "modern-extra.js").write_text(MODERN_EXTRA_JS)
        (self.root / "form.html").write_text(FORM_HTML)
        (self.root / "formdone.html").write_text("<html><body><p>Form sent</p></body></html>")
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


# /enc/<kind>: ENCODED_TEXT sent compressed and/or chunked (as servers do even
# when not asked); the browser decodes it (kernel/net/inflate.asm)
ENCODED_TEXT = "".join(f"line {i}: the quick brown fox jumps over the lazy dog\n" for i in range(3000))


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if not self.path.startswith("/enc/"):
            return super().do_GET()
        kind = self.path[5:]
        data = ENCODED_TEXT.encode()
        body = {"gzip": gzip.compress(data), "deflate": zlib.compress(data), "stored": gzip.compress(data, 0),
                "chunked": data, "gzip-chunked": gzip.compress(data)}[kind]
        self.protocol_version = "HTTP/1.1"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        if kind != "chunked":
            self.send_header("Content-Encoding", "deflate" if kind == "deflate" else "gzip")
        self.send_header("Connection", "close")
        if kind.endswith("chunked"):
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(0, len(body), 4000):
                part = body[i:i + 4000]
                self.wfile.write(b"%x\r\n" % len(part) + part + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


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

    def test_compressed_and_chunked_bodies(self):
        # what fetch and XMLHttpRequest get is the text itself
        want = f"{len(ENCODED_TEXT)} line 2999"
        with HostWebServer() as web:
            base = f"http://10.0.2.2:{web.port}/enc"
            for kind in ("gzip", "deflate", "stored", "chunked", "gzip-chunked"):
                out = self.vm.run(f"js fetch('{base}/{kind}').then(r => r.text()).then(t => console.log(t.length, "
                                  "t.trim().split('\\n').pop().slice(0, 9)))", timeout=30)
                self.assertIn(want, out, kind)

    def test_fetch_and_xhr_from_js(self):
        with HostWebServer() as web:
            base = f"http://10.0.2.2:{web.port}"
            out = self.vm.run(f"js fetch('{base}/data.json').then(r => {{ console.log(r.status, r.ok, "
                              f"r.headers.get('content-type')); return r.json() }}).then(d => console.log(d.name, d.list))",
                              timeout=30)
            self.assertIn("200 true application/json", out)
            self.assertIn("ag [ 1, 2, 3 ]", out)
            out = self.vm.run(f"js (async () => {{ const r = await fetch('{base}/missing.html'); "
                              f"console.log(r.status, r.ok) }})()", timeout=30)
            self.assertIn("404 false", out)
            out = self.vm.run("js fetch('http://10.0.2.2:1/x').catch(e => console.log(e.name, e.message))", timeout=30)
            self.assertIn("TypeError Failed to fetch", out)
            out = self.vm.run(f"js var x = new XMLHttpRequest(); x.responseType = 'json'; x.onreadystatechange = () => "
                              f"console.log('state', x.readyState); x.addEventListener('load', () => console.log('xhr', "
                              f"x.status, x.response.list)); x.open('GET', '{base}/data.json'); x.send()", timeout=30)
            for expected in ("state 1", "state 4", "xhr 200 [ 1, 2, 3 ]"):
                self.assertIn(expected, out)
            self.assertLess(out.index("state 4"), out.index("xhr 200"))
            out = self.vm.run(f"js var x = new XMLHttpRequest(); x.open('GET', '{base}/data.json', false); x.send(); "
                              f"[x.status, x.readyState, x.responseText.length]", timeout=30)
            self.assertIn("[ 200, 4, 33 ]", out)

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
