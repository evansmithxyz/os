"""JavaScript engine (kernel/js/) through the `js` shell command.

Expected values are what Node.js prints for the same code.
"""

import time
import unittest

from tests.harness import PROMPT, OSTestCase

DEMO_JS = b"""// a multi-line script from the disk
function Counter(start) {
    this.count = start;
}
Counter.prototype.next = function () {
    return ++this.count;
};

var c = new Counter(10);
c.next();
console.log('count:', c.next());

const squares = [];
for (let i = 1; i <= 5; i++) {
    squares.push(i * i);
}
console.log(squares.join(' + '), '=', total(squares));

function total(list) {          // hoisted
    var sum = 0;
    for (var v of list) sum += v;
    return sum;
}

var words = { one: 1, two: 2, three: 3 };
var keys = '';
for (var k in words) {
    if (k === 'two') continue;
    keys += k + ';';
}
keys
"""


class JavaScriptTest(OSTestCase):
    shared_vm = True
    disk_files = {"demo.js": DEMO_JS}

    def js(self, code: str) -> str:
        return self.vm.run("js " + code, timeout=20).strip()

    def assertJs(self, code: str, expected: str):
        self.assertEqual(self.js(code), expected, code)

    # --- values -----------------------------------------------------------------
    def test_numbers_print_like_node(self):
        self.assertJs("1 + 2", "3")
        self.assertJs("0.1 + 0.2", "0.30000000000000004")
        self.assertJs("[1e21, 1e-7, 123.456, -0, 1/3, 5e-324, 1.7976931348623157e308, 123e-20]",
                      "[ 1e+21, 1e-7, 123.456, -0, 0.3333333333333333, 5e-324, 1.7976931348623157e+308, 1.23e-18 ]")
        self.assertJs("[0x10, 0o17, 0b11, 1_000_000, .5, 5., 2 ** 10, 7 % 3, -7 % 3, 5.5 % 2]",
                      "[ 16, 15, 3, 1000000, 0.5, 5, 1024, 1, -1, 1.5 ]")
        self.assertJs("[1e300 * 1e10, 0/0, 1 / -0, 9007199254740993]",
                      "[ Infinity, NaN, -Infinity, 9007199254740992 ]")

    def test_strings(self):
        self.assertJs("'a' + 'b' + 1", "'ab1'")
        self.assertJs("['hello'.toUpperCase(), '  x '.trim(), 'abc'.charAt(1), 'abc'.charCodeAt(0), "
                      "'hello'.indexOf('l'), 'hello'.slice(-3), 'hello'.substring(1, 3), 'abc'[2], 'abc'.length]",
                      "[ 'HELLO', 'x', 'b', 97, 2, 'llo', 'el', 'c', 3 ]")
        self.assertJs(r"""['tab\tq\'s\n', 'say "hi"']""", r"""[ "tab\tq's\n", 'say "hi"' ]""")
        self.assertJs("String.fromCharCode(72, 105) + String(12) + String(null)", "'Hi12null'")

    def test_objects_and_arrays(self):
        self.assertJs("var o = {a: 1, b: {c: [1, 2, {d: 3}]}}; o.b.c[2].d = 4; o",
                      "{ a: 1, b: { c: [ 1, 2, [Object] ] } }")
        self.assertJs("var a = [1, 2, 3]; a.push(4, 5); [a.length, a.join('-'), a.pop(), a.indexOf(3), a.slice(1, 3)]",
                      "[ 5, '1-2-3-4-5', 5, 2, [ 2, 3 ] ]")
        self.assertJs("var a = [1, , 3]; a[6] = 7; a", "[ 1, <1 empty item>, 3, <3 empty items>, 7 ]")
        self.assertJs("var o = {x: 1, y: 2}; delete o.x; ['x' in o, 'y' in o, o, 0 in [5], 'length' in []]",
                      "[ false, true, { y: 2 }, true, true ]")
        self.assertJs("var o = {'quoted key': 1, if: 2}; o.if + o['quoted key'] + Object.keys(o).length",
                      "5")

    def test_console_log(self):
        out = self.js("console.log('hi', 42, [1, 'x'], {a: null}, undefined, function f() {})")
        self.assertEqual(out, "hi 42 [ 1, 'x' ] { a: null } undefined [Function: f]")

    # --- the language -----------------------------------------------------------
    def test_closures_and_scopes(self):
        self.assertJs("function counter() { var n = 0; return function () { return ++n } } "
                      "var c = counter(); c(); c(); c()", "3")
        self.assertJs("var fs = []; for (let i = 0; i < 3; i++) fs.push(function () { return i }); "
                      "fs[0]() + fs[1]() * 10 + fs[2]() * 100", "210")
        self.assertJs("var fs = []; for (var i = 0; i < 3; i++) fs.push(function () { return i }); fs[0]()", "3")
        self.assertJs("let a = 1; { let a = 2; a = 3 } a", "1")
        self.assertJs("function outer() { var x = 1; function mid() { var y = 2; "
                      "return function () { return x + y } } return mid() } outer()()", "3")

    def test_functions(self):
        self.assertJs("function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) } fib(20)", "6765")
        self.assertJs("function f() { return arguments.length + ':' + arguments[1] } f(1, 'two', 3)", "'3:two'")
        self.assertJs("var g = function fact(n) { return n <= 1 ? 1 : n * fact(n - 1) }; g(10)", "3628800")
        self.assertJs("hoisted(); function hoisted() { return 'ok' } hoisted()", "'ok'")
        self.assertJs("function P(x) { this.x = x } P.prototype.get = function () { return this.x * 2 }; "
                      "var p = new P(21); [p.get(), p instanceof P, p.constructor === P, p]",
                      "[ 42, true, true, P { x: 21 } ]")
        self.assertJs("var o = {n: 5, twice: function () { return this.n * 2 }}; o.twice()", "10")

    def test_control_flow(self):
        self.assertJs("var r = ''; outer: for (var i = 0; i < 3; i++) { for (var j = 0; j < 3; j++) { "
                      "if (j == 1) continue outer; if (i == 2) break outer; r += i + '' + j + ' ' } } r", "'00 10 '")
        self.assertJs("switch (3) { case 1: 'one'; break; case 3: 'three'; case 4: 'four'; break; default: 'x' }",
                      "'four'")
        self.assertJs("var out = []; for (var k in {a: 1, b: 2, c: 3}) { switch (k) { case 'b': continue; "
                      "default: out.push(k) } } out", "[ 'a', 'c' ]")
        self.assertJs("var n = 0; do { n++ } while (n < 10); var m = 0; while (true) { if (++m > 5) break } [n, m]",
                      "[ 10, 6 ]")
        self.assertJs("var t = 0; for (var v of [1, 2, 3]) t += v; for (var ch of 'ab') t += ch; t", "'6ab'")

    def test_operators(self):
        self.assertJs("[1 == '1', 1 === '1', null == undefined, null == 0, NaN == NaN, '' == 0, [] + [], [1,2] + '']",
                      "[ true, false, true, false, false, true, '', '1,2' ]")
        self.assertJs("typeof 1 + typeof 'x' + typeof {} + typeof null + typeof undefined + typeof function(){} "
                      "+ typeof nope", "'numberstringobjectobjectundefinedfunctionundefined'")
        self.assertJs("[5 & 3, 5 | 3, 5 ^ 3, ~5, 1 << 4, -16 >> 2, -16 >>> 28, 2 ** 3 ** 2]",
                      "[ 1, 7, 6, -6, 16, -4, 15, 512 ]")
        self.assertJs("var x = null; var y = x ?? 'd'; var z = 0 || 'e'; var w = 1 && 'f'; [y, z, w]",
                      "[ 'd', 'e', 'f' ]")
        self.assertJs("var a = 5; a += 2; a *= 3; a -= 1; a /= 4; a %= 3; var b; b ??= 7; [a, b, 'b' < 'a', 2 < 10, '2' < '10']",
                      "[ 2, 7, false, true, false ]")
        self.assertJs("({toString: function () { return 'custom' }}) + '!'", "'custom!'")

    def test_builtins(self):
        self.assertJs("[parseInt('42px'), parseInt('0x1F'), parseInt('ff', 16), parseFloat('3.14abc'), "
                      "Number(' 12 '), Number('1e3'), Number('abc'), +'0b101', isNaN('x'), isFinite('5')]",
                      "[ 42, 31, 255, 3.14, 12, 1000, NaN, 5, true, true ]")
        self.assertJs("[Math.floor(-1.5), Math.ceil(1.2), Math.round(2.5), Math.round(-2.5), Math.max(1, 5, 3), "
                      "Math.min(4, 2), Math.abs(-3), Math.sqrt(2), Math.pow(2, 0.5), Math.PI]",
                      "[ -2, 2, 3, -2, 5, 2, 3, 1.4142135623730951, 1.4142135623730951, 3.141592653589793 ]")
        self.assertJs("[(1.005).toFixed(2), (1.45).toFixed(1), (0).toFixed(2), (-1.5).toFixed(0), "
                      "(0.1).toFixed(20), (255).toString(16), (-255).toString(2), (0.5).toString(2)]",
                      "[ '1.00', '1.4', '0.00', '-2', '0.10000000000000000555', 'ff', '-11111111', '0.1' ]")
        self.assertJs("var r = Math.random(); r >= 0 && r < 1 && Math.random() !== r", "true")
        self.assertJs("[Array(3).length, Array.isArray([]), Object.keys({a: 1, b: 2}), ({}).toString(), "
                      "[1, [2, 3]].toString(), ({}).hasOwnProperty('x')]",
                      "[ 3, true, [ 'a', 'b' ], '[object Object]', '1,2,3', false ]")

    # --- errors -------------------------------------------------------------------
    def test_errors(self):
        self.assertJs("nope()", "Uncaught ReferenceError: nope is not defined (line 1)")
        self.assertJs("var q = 1; q()", "Uncaught TypeError: q is not a function (line 1)")
        self.assertJs("undefined.foo", "Uncaught TypeError: Cannot read properties of undefined (reading 'foo') (line 1)")
        self.assertJs("const k = 1; k = 2", "Uncaught TypeError: Assignment to constant variable. (line 1)")
        self.assertJs("throw 'boom'", "Uncaught 'boom' (line 1)")
        self.assertJs("1 +", "Uncaught SyntaxError: Unexpected end of input (line 1)")
        self.assertJs("var x = )", "Uncaught SyntaxError: Unexpected token ')' (line 1)")
        self.assertJs("function deep(n) { return deep(n + 1) } deep(0)",
                      "Uncaught RangeError: Maximum call stack size exceeded (line 1)")
        self.assertJs("[1].map(x => x)", "Uncaught SyntaxError: => (arrow functions) is not supported yet (line 1)")

    def test_ctrl_c_stops_a_runaway_script(self):
        self.vm.send("js for (;;) {}\r")
        time.sleep(1.0)
        self.vm.send("\x03")
        out = self.vm.expect(PROMPT, timeout=10)
        self.assertIn("Uncaught Error: Script interrupted", out)
        self.assertEqual(self.js("1 + 1"), "2", "the engine works again afterwards")

    # --- scripts on the disk ------------------------------------------------------
    def test_runs_a_file(self):
        out = self.vm.run("js demo.js", timeout=20)
        self.assertIn("count: 12", out)
        self.assertIn("1 + 4 + 9 + 16 + 25 = 55", out)
        self.assertIn("'one;three;'", out)


if __name__ == "__main__":
    unittest.main()
