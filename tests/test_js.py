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

    def js(self, code: str, timeout: float = 20) -> str:
        out = self.vm.run("js " + code, timeout=timeout)
        # (collections log "[klog] js gc: ..." lines on the serial port)
        return "\n".join(l for l in out.splitlines() if not l.startswith("[klog]")).strip()

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
        self.assertJs("/ab+c/.test('abbc')",
                      "Uncaught SyntaxError: /regular expressions/ is not supported yet (line 1)")

    # --- step 3: everyday JavaScript ---------------------------------------------
    def test_exceptions(self):
        self.assertJs("try { null.x } catch (e) { [e instanceof TypeError, e.message] }",
                      """[ true, "Cannot read properties of null (reading 'x')" ]""")
        self.assertJs("var log = []; function f() { try { return 'r' } finally { log.push('fin') } } [f(), log]",
                      "[ 'r', [ 'fin' ] ]")
        self.assertJs("var e = new RangeError('bad'); [e.name, e.message, String(e), e instanceof Error]",
                      "[ 'RangeError', 'bad', 'RangeError: bad', true ]")
        self.assertJs("var n = 0; for (var i = 0; i < 3; i++) { try { if (i == 1) continue; n += 10 } finally { n++ } } n",
                      "23")
        self.assertJs("try { throw {code: 7} } catch ({code}) { code }", "7")
        self.assertJs("throw new TypeError('x')", "Uncaught TypeError: x (line 1)")

    def test_functions_step3(self):
        self.assertJs("var o = {n: 1, f() { return [1, 2].map(x => x + this.n) }}; o.f()", "[ 2, 3 ]")
        self.assertJs("function g(a, b = a * 2, ...rest) { return [a + b, rest] } g(3, undefined, 4, 5)",
                      "[ 9, [ 4, 5 ] ]")
        self.assertJs("function sum(...n) { return n.reduce((a, b) => a + b, 0) } sum(...[1, 2, 3], 4)", "10")
        self.assertJs("`${1 + 1} is ${'tw' + 'o'}!`", "'2 is two!'")
        self.assertJs("var {a, b: [c, d = 4], ...rest} = {a: 1, b: [3], e: 5, f: 6}; [a, c, d, rest]",
                      "[ 1, 3, 4, { e: 5, f: 6 } ]")
        self.assertJs("var x = 1, y = 2; [x, y] = [y, x]; [x, y, [...'hi', ...[3]], {...{p: 1}, q: 2}]",
                      "[ 2, 1, [ 'h', 'i', 3 ], { p: 1, q: 2 } ]")
        self.assertJs("var o = {a: {b: null}}; [o?.a?.b?.c, o.x?.y, o.a?.['b'], o.f?.()]",
                      "[ undefined, undefined, null, undefined ]")
        self.assertJs("var o = {_v: 1, get v() { return this._v * 2 }, set v(x) { this._v = x }}; o.v = 5; [o.v, o]",
                      "[ 10, { _v: 5, v: [Getter/Setter] } ]")

    def test_classes(self):
        self.assertJs("class Animal { constructor(n) { this.name = n } speak() { return this.name + ' speaks' } "
                      "static make(n) { return new this(n) } } "
                      "class Dog extends Animal { speak() { return super.speak() + ' (woof)' } } "
                      "var d = Dog.make('Rex'); [d.speak(), d instanceof Animal, d]",
                      "[ 'Rex speaks (woof)', true, Dog { name: 'Rex' } ]")
        self.assertJs("class C { n = 3; static s = 'st'; get dbl() { return this.n * 2 } } var c = new C(); [c.n, C.s, c.dbl, c]",
                      "[ 3, 'st', 6, C { n: 3 } ]")
        self.assertJs("class MyErr extends Error { constructor(m) { super(m); this.name = 'MyErr' } } "
                      "try { throw new MyErr('oops') } catch (e) { [e.message, e instanceof MyErr, e instanceof Error, String(e)] }",
                      "[ 'oops', true, true, 'MyErr: oops' ]")
        self.assertJs("class K {} K()", "Uncaught TypeError: Class constructor K cannot be invoked without 'new' (line 1)")
        self.assertJs("class P { constructor(x) { this.x = x } } var B = P.bind(null, 5); new B().x", "5")

    def test_array_methods(self):
        self.assertJs("[[1, 2, 3].map(x => x * 2), [1, 2, 3, 4].filter(x => x % 2), [1, 2, 3].reduce((a, b) => a + b), "
                      "[1, 2, 3].reduceRight((a, b) => a + '' + b)]",
                      "[ [ 2, 4, 6 ], [ 1, 3 ], 6, '321' ]")
        self.assertJs("[[3, 1, 2].sort(), [10, 9, 1, 100].sort(), [10, 9, 1, 100].sort((a, b) => a - b), "
                      "[3, undefined, 1, , 2].sort()]",
                      "[ [ 1, 2, 3 ], [ 1, 10, 100, 9 ], [ 1, 9, 10, 100 ], [ 1, 2, 3, undefined, <1 empty item> ] ]")
        self.assertJs("[{k: 1, v: 'a'}, {k: 0, v: 'b'}, {k: 1, v: 'c'}, {k: 0, v: 'd'}].sort((a, b) => a.k - b.k)"
                      ".map(x => x.v).join('')", "'bdac'")
        self.assertJs("var a = [1, 2, 3, 4, 5]; var r = a.splice(1, 2, 'x', 'y', 'z'); a.unshift(0); a.shift(); [a, r]",
                      "[ [ 1, 'x', 'y', 'z', 4, 5 ], [ 2, 3 ] ]")
        self.assertJs("[[1, [2, [3, [4]]]].flat(Infinity), [1, 2].flatMap(x => [x, x * 10]), [1, 2, 3].at(-1), "
                      "[NaN].includes(NaN), [5, 12, 8].find(x => x > 6), [5, 12, 8].findIndex(x => x > 6), "
                      "[1, 2, 3].some(x => x > 2), [1, 2, 3].every(x => x > 2)]",
                      "[ [ 1, 2, 3, 4 ], [ 1, 10, 2, 20 ], 3, true, 12, 1, true, false ]")
        self.assertJs("[Array.from('abc'), Array.from({length: 3}, (v, i) => i * i), Array.of(7, 8), "
                      "new Array(3).fill(0), [1].concat([2, 3], 4), [1, 2, 3].reverse()]",
                      "[ [ 'a', 'b', 'c' ], [ 0, 1, 4 ], [ 7, 8 ], [ 0, 0, 0 ], [ 1, 2, 3, 4 ], [ 3, 2, 1 ] ]")
        self.assertJs("var out = []; ['a', 'b'].forEach((x, i, arr) => out.push(x + i + arr.length)); out",
                      "[ 'a02', 'b12' ]")
        self.assertJs("[1].map(3)", "Uncaught TypeError: 3 is not a function (line 1)")

    def test_string_methods(self):
        self.assertJs("['a,b,,c'.split(','), 'hello'.split(''), 'a b c'.split(' ', 2), 'abc'.split()]",
                      "[ [ 'a', 'b', '', 'c' ], [ 'h', 'e', 'l', 'l', 'o' ], [ 'a', 'b' ], [ 'abc' ] ]")
        self.assertJs("['a-b-c'.replace('-', '+'), 'a-b-c'.replaceAll('-', '+'), 'abc'.replace('b', m => m.toUpperCase()), "
                      "'abc'.replace('b', '[$&$`]'), 'ab'.replaceAll('', '.')]",
                      "[ 'a+b-c', 'a+b+c', 'aBc', 'a[ba]c', '.a.b.' ]")
        self.assertJs("['5'.padStart(3, '0'), 'ab'.padEnd(5) + '|', 'ab'.repeat(3), '  hi  '.trimStart(), "
                      "'  hi  '.trimEnd(), 'abc'.at(-1), 'a'.concat('b', 1)]",
                      "[ '005', 'ab   |', 'ababab', 'hi  ', '  hi', 'c', 'ab1' ]")
        self.assertJs("['hello'.includes('ell'), 'hello'.startsWith('he'), 'hello'.endsWith('lo'), "
                      "'hello'.endsWith('l', 4), 'hello'.lastIndexOf('l'), 'b'.localeCompare('a')]",
                      "[ true, true, true, true, 3, 1 ]")
        self.assertJs("'x'.repeat(-1)", "Uncaught RangeError: Invalid count value (line 1)")

    def test_object_and_function_methods(self):
        self.assertJs("[Object.entries({a: 1, b: 2}), Object.values({a: 1, b: 2}), Object.assign({a: 1}, {b: 2}, null), "
                      "Object.fromEntries([['x', 1]])]",
                      "[ [ [ 'a', 1 ], [ 'b', 2 ] ], [ 1, 2 ], { a: 1, b: 2 }, { x: 1 } ]")
        self.assertJs("var p = {hi() { return 'hi ' + this.n }}; var o = Object.create(p); o.n = 'x'; "
                      "[o.hi(), Object.getPrototypeOf(o) === p, p.isPrototypeOf(o), Object.keys(Object.create(null))]",
                      "[ 'hi x', true, true, [] ]")
        self.assertJs("var o = {}; Object.defineProperty(o, 'x', {value: 42}); o.x = 5; "
                      "[o.x, Object.keys(o), Object.getOwnPropertyNames(o), Object.getOwnPropertyDescriptor(o, 'x')]",
                      "[ 42, [], [ 'x' ], { value: 42, writable: false, enumerable: false, configurable: false } ]")
        self.assertJs("var f = Object.freeze({a: 1}); f.a = 2; [f.a, Object.is(NaN, NaN), Object.is(0, -0)]",
                      "[ 1, true, false ]")
        self.assertJs("function f(a, b) { return this.x + a + b } [f.call({x: 1}, 2, 3), f.apply({x: 10}, [20, 30]), "
                      "f.bind({x: 100}, 200)(300)]", "[ 6, 60, 600 ]")

    def test_number_and_math(self):
        self.assertJs("[Number.isInteger(5), Number.isInteger(5.5), Number.isSafeInteger(2 ** 53), Number.isNaN('x'), "
                      "Number.isFinite(1 / 0), Number.parseFloat('1.5x')]",
                      "[ true, false, false, false, false, 1.5 ]")
        self.assertJs("[Math.hypot(3, 4), Math.cbrt(27), Math.cbrt(-8), Math.log10(1000), Math.log2(8), Math.sinh(1), "
                      "Math.cosh(1), Math.tanh(0.5), Math.tanh(100)]",
                      "[ 5, 3, -2, 3, 3, 1.1752011936438014, 1.5430806348152437, 0.46211715726000974, 1 ]")
        self.assertJs("[Math.asin(1), Math.acos(0.5), Math.expm1(1e-10), Math.fround(5.05), Math.clz32(1), Math.imul(3, 4)]",
                      "[ 1.5707963267948966, 1.0471975511965979, 1.00000000005e-10, 5.050000190734863, 31, 12 ]")

    def test_json(self):
        self.assertJs("""JSON.stringify({a: 1, b: [1, 'two', null, true], c: {d: undefined, e: () => 1}, n: NaN, f: 'q"'})""",
                      """'{"a":1,"b":[1,"two",null,true],"c":{},"n":null,"f":"q\\\\""}'""")
        self.assertJs("JSON.stringify([1, {a: 2}], null, 2)", """'[\\n  1,\\n  {\\n    "a": 2\\n  }\\n]'""")
        self.assertJs("JSON.stringify({d: {toJSON() { return 'D' }}, x: 1}, (k, v) => typeof v === 'number' ? v * 10 : v)",
                      """'{"d":"D","x":10}'""")
        self.assertJs("var o = {}; o.o = o; JSON.stringify(o)",
                      "Uncaught TypeError: Converting circular structure to JSON (line 1)")
        self.assertJs("""JSON.parse('{"a": [1, 2.5e3, -0.5], "b": {"c": "x\\\\u0041\\\\ty"}, "d": true, "e": null}')""",
                      "{ a: [ 1, 2500, -0.5 ], b: { c: 'xA\\ty' }, d: true, e: null }")
        self.assertJs("JSON.parse('{bad}')", "Uncaught SyntaxError: Unexpected token 'b' in JSON (line 1)")

    def test_garbage_collector(self):
        # each line hands out far more than the heap holds: only collections make room
        out = self.vm.run("js var s; for (var i = 0; i < 100000; i++) s = 'x'.repeat(1000); s.length", timeout=120)
        self.assertIn("[klog] js gc: live bytes", out)
        self.assertTrue(out.strip().endswith("1000"), out[-300:])
        self.assertJs("var keep = []; for (var i = 0; i < 200000; i++) { var o = {i: i, s: 'v' + i}; "
                      "if (i % 100 == 0) keep.push(o) } keep.length + keep[1999].s", "'2000v199900'")
        self.assertJs("function mk(n) { var x = [n]; return () => x[0] } var fs = []; "
                      "for (var i = 0; i < 300000; i++) { var f = mk(i); if (i % 1000 == 0) fs.push(f) } fs[299]()",
                      "299000")
        self.assertJs("var t = 0; for (var k = 0; k < 30; k++) { var big = JSON.parse(JSON.stringify("
                      "Array.from({length: 2000}, (v, i) => ({i, s: 'q' + i})))); t += big[1999].i } t", "59970")

    # --- step 4: timers and async --------------------------------------------------
    def test_promises(self):
        self.assertJs("[Promise.resolve(5), new Promise(() => {}), Promise.reject(1).catch(() => {}) instanceof Promise]",
                      "[ Promise { 5 }, Promise { <pending> }, true ]")
        self.assertJs("Promise.resolve(1).then(v => v + 1).then(v => console.log('then', v)); 'sync'", "'sync'\nthen 2")
        self.assertJs("Promise.reject(new Error('no')).catch(e => e.message).finally(() => console.log('fin'))"
                      ".then(v => console.log('after', v)); 1", "1\nfin\nafter no")
        self.assertJs("new Promise(r => r(Promise.resolve('adopted'))).then(console.log); 0", "0\nadopted")
        self.assertJs("Promise.all([1, Promise.resolve(2), new Promise(r => setTimeout(() => r(3), 10))])"
                      ".then(v => console.log('all', v)); 0", "0\nall [ 1, 2, 3 ]")
        self.assertJs("Promise.allSettled([Promise.reject(1), 2]).then(v => console.log(JSON.stringify(v))); 0",
                      """0\n[{"status":"rejected","reason":1},{"status":"fulfilled","value":2}]""")
        self.assertJs("Promise.race([new Promise(r => setTimeout(() => r('slow'), 50)), "
                      "new Promise(r => setTimeout(() => r('fast'), 10))]).then(console.log); 0", "0\nfast")
        self.assertJs("Promise.any([Promise.reject(1), Promise.reject(2)]).catch(e => console.log(e.name, e.errors)); 0",
                      "0\nAggregateError [ 1, 2 ]")
        self.assertJs("Promise.reject(42); 0", "0\nUncaught (in promise) 42")

    def test_async_functions(self):
        self.assertJs("async function f(x) { return x * 2 } [f(21), f]", "[ Promise { 42 }, [AsyncFunction: f] ]")
        self.assertJs("async function g() { var a = await 1; var b = await Promise.resolve(2); return a + b } "
                      "g().then(v => console.log('g', v)); 0", "0\ng 3")
        self.assertJs("async function h() { try { await Promise.reject(new TypeError('bad')) } catch (e) { "
                      "return 'caught ' + e.message } finally { console.log('finally') } } h().then(console.log); 0",
                      "0\nfinally\ncaught bad")
        self.assertJs("async function k() { await 1; null.x } k().catch(e => console.log('k:', e.message)); 0",
                      "0\nk: Cannot read properties of null (reading 'x')")
        self.assertJs("var o = {v: 9, async m() { return this.v }}; class C { async get() { await null; return 'cls' } } "
                      "o.m().then(console.log); new C().get().then(console.log); (async x => x + 1)(1).then(console.log); 0",
                      "0\n9\n2\ncls")
        self.assertJs("var order = []; (async () => { order.push(1); await undefined; order.push(3) })(); order.push(2); "
                      "queueMicrotask(() => console.log(order.join())); 0", "0\n1,2,3")
        self.assertJs("async function thrower() { await 1; throw new RangeError('late') } thrower(); 0",
                      "0\nUncaught (in promise) RangeError: late")
        self.assertJs("var await = 5; async function a() { return await await 2 } a().then(v => console.log(v, await)); 0",
                      "0\n2 5")

    def test_timers_and_event_loop(self):
        self.assertJs("console.log(1); setTimeout(() => console.log(4), 20); Promise.resolve().then(() => console.log(3)); "
                      "console.log(2)", "1\n2\n3\n4")
        self.assertJs("const sleep = ms => new Promise(r => setTimeout(r, ms)); (async () => { for (let i = 0; i < 3; i++) "
                      "{ await sleep(20); console.log('tick', i) } })(); 0", "0\ntick 0\ntick 1\ntick 2")
        self.assertJs("var n = 0; var id = setInterval(() => { if (++n == 3) { clearInterval(id); console.log('done', n) } }, 10); "
                      "var t = setTimeout(() => console.log('never'), 5); clearTimeout(t); typeof id",
                      "'number'\ndone 3")
        self.assertJs("setTimeout((a, b) => console.log(a + b), 0, 'x', 'y'); requestAnimationFrame(t => "
                      "console.log('frame', typeof t, t >= 0)); var t0 = performance.now(); setTimeout(() => "
                      "console.log(performance.now() - t0 >= 50), 50); 0", "0\nxy\nframe number true\ntrue")
        self.assertJs("setTimeout(() => { throw new Error('in timer') }, 0); setTimeout(() => console.log('next'), 10); 0",
                      "0\nUncaught Error: in timer (line 1)\nnext")

    def test_ctrl_c_stops_waiting_for_timers(self):
        self.vm.send("js setInterval(() => {}, 1000)\r")
        time.sleep(1.0)
        self.vm.send("\x03")
        self.vm.expect(PROMPT, timeout=10)
        self.assertEqual(self.js("1 + 1"), "2")

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
