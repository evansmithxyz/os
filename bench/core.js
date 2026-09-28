// Benchmarks for the JavaScript engine: python tools/profile.py bench/core.js
// Each line prints its time in milliseconds (the timer ticks every 1 ms).
var total = 0;
function time(name, f) {
    var t = performance.now();
    var r = f();
    var ms = performance.now() - t;
    total += ms;
    console.log(name + ': ' + ms + ' ms (' + r + ')');
}

time('loop', () => { var s = 0; for (var i = 0; i < 1000000; i++) s += i; return s });
time('fib', () => { function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) } return fib(24) });
time('props', () => { var o = {a: 1, b: 2, c: 3, d: 4}; var s = 0; for (var i = 0; i < 300000; i++) s += o.a + o.d; return s });
time('methods', () => {
    class P { constructor(x) { this.x = x } twice() { return this.x * 2 } }
    var p = new P(3); var s = 0;
    for (var i = 0; i < 200000; i++) s += p.twice();
    return s;
});
time('arrays', () => {
    var a = []; for (var i = 0; i < 200000; i++) a.push(i);
    var s = 0; for (var j = 0; j < a.length; j++) s += a[j];
    return s;
});
time('closures', () => { function mk(n) { return () => n } var s = 0; for (var i = 0; i < 100000; i++) s += mk(i)(); return s });
time('strings', () => { var s = ''; for (var i = 0; i < 20000; i++) s += 'ab'; return s.length });
time('objects', () => { var list = []; for (var i = 0; i < 50000; i++) list.push({id: i, name: 'n' + i}); return list.length });
time('keyed', () => { var o = {}; for (var i = 0; i < 20000; i++) o['k' + (i % 100)] = i; return Object.keys(o).length });
time('map', () => { var m = new Map(); for (var i = 0; i < 50000; i++) m.set(i, i); var s = 0; for (var k = 0; k < 50000; k++) s += m.get(k); return s });
time('sort', () => { var a = []; for (var i = 0; i < 20000; i++) a.push((i * 7919) % 20000); a.sort((x, y) => x - y); return a[5] });
time('json', () => { var o = {list: Array.from({length: 2000}, (v, i) => ({i, s: 'x' + i}))}; return JSON.parse(JSON.stringify(o)).list.length });
time('regex', () => { var n = 0; for (var i = 0; i < 5000; i++) if (/^(\w+)@(\w+)\.com$/.test('user' + i + '@host.com')) n++; return n });
time('array methods', () => { var a = Array.from({length: 50000}, (v, i) => i); return a.map(x => x * 2).filter(x => x % 3).reduce((p, c) => p + c, 0) });
console.log('total: ' + total + ' ms');
