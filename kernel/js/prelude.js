// Antigravity OS - the parts of the JavaScript library written in JavaScript.
// Every realm runs this once its native built-ins exist (js_run_prelude in
// kernel/js/js.asm). Everything is defined non-enumerable, like the built-ins.
(function (global) {
'use strict';

function def(obj, name, value) {
    Object.defineProperty(obj, name, { value: value, writable: true, configurable: true, enumerable: false });
}
function defAll(obj, props) {
    for (var k of Object.keys(props)) def(obj, k, props[k]);
}
function isObject(v) {
    return v !== null && (typeof v === 'object' || typeof v === 'function');
}

// --- console -----------------------------------------------------------------------
var counts = Object.create(null), timers = Object.create(null), indent = '';
function log() { console.log.apply(console, indent ? [indent.slice(1)].concat(Array.from(arguments)) : arguments) }
defAll(console, {
    trace: log, dir: log, dirxml: log, table: log,
    assert: function assert(ok) { if (!ok) log.apply(null, ['Assertion failed:'].concat(Array.prototype.slice.call(arguments, 1))) },
    count: function count(label) { label = label === undefined ? 'default' : String(label); counts[label] = (counts[label] || 0) + 1; log(label + ': ' + counts[label]) },
    countReset: function countReset(label) { counts[label === undefined ? 'default' : String(label)] = 0 },
    group: function group() { if (arguments.length) log.apply(null, arguments); indent += '  ' },
    groupCollapsed: function groupCollapsed() { if (arguments.length) log.apply(null, arguments); indent += '  ' },
    groupEnd: function groupEnd() { indent = indent.slice(2) },
    time: function time(label) { timers[label === undefined ? 'default' : String(label)] = performance.now() },
    timeLog: function timeLog(label) { label = label === undefined ? 'default' : String(label); log(label + ': ' + (performance.now() - timers[label]) + ' ms') },
    timeEnd: function timeEnd(label) { label = label === undefined ? 'default' : String(label); log(label + ': ' + (performance.now() - timers[label]) + ' ms'); delete timers[label] },
    clear: function clear() { },
});

// --- Reflect ---------------------------------------------------------------------
var Reflect = {};
defAll(Reflect, {
    apply: function apply(f, self, args) { return Function.prototype.apply.call(f, self, args) },
    construct: function construct(F, args, newTarget) {
        var o = new (Function.prototype.bind.apply(F, [null].concat(Array.from(args))))();
        if (newTarget !== undefined && newTarget !== F) Object.setPrototypeOf(o, newTarget.prototype);
        return o;
    },
    defineProperty: function defineProperty(o, k, d) {
        try { Object.defineProperty(o, k, d); return true } catch (e) { return false }
    },
    deleteProperty: function deleteProperty(o, k) { return delete o[k] },
    get: function get(o, k) { return o[k] },
    set: function set(o, k, v) { o[k] = v; return true },
    has: function has(o, k) { return k in o },
    ownKeys: function ownKeys(o) { return Object.getOwnPropertyNames(o).concat(Object.getOwnPropertySymbols(o)) },
    getOwnPropertyDescriptor: function getOwnPropertyDescriptor(o, k) { return Object.getOwnPropertyDescriptor(o, k) },
    getPrototypeOf: function getPrototypeOf(o) { return Object.getPrototypeOf(o) },
    setPrototypeOf: function setPrototypeOf(o, p) { Object.setPrototypeOf(o, p); return true },
    isExtensible: function isExtensible(o) { return Object.isExtensible(o) },
    preventExtensions: function preventExtensions(o) { Object.preventExtensions(o); return true },
});
def(Reflect, Symbol.toStringTag, 'Reflect');
def(global, 'Reflect', Reflect);

// --- Object ----------------------------------------------------------------------
// (freezing is recorded, so isFrozen and friends can answer)
var frozen = new WeakSet(), sealed = new WeakSet(), fixed = new WeakSet();
var nativeFreeze = Object.freeze, nativeSeal = Object.seal, nativePrevent = Object.preventExtensions;
defAll(Object, {
    freeze: function freeze(o) {
        if (isObject(o)) { nativeFreeze(o); frozen.add(o); sealed.add(o); fixed.add(o) }
        return o;
    },
    seal: function seal(o) {
        if (isObject(o)) { if (nativeSeal) nativeSeal(o); sealed.add(o); fixed.add(o) }
        return o;
    },
    preventExtensions: function preventExtensions(o) {
        if (isObject(o)) { if (nativePrevent) nativePrevent(o); fixed.add(o) }
        return o;
    },
    isFrozen: function isFrozen(o) { return !isObject(o) || frozen.has(o) },
    isSealed: function isSealed(o) { return !isObject(o) || sealed.has(o) },
    isExtensible: function isExtensible(o) { return isObject(o) && !fixed.has(o) },
    hasOwn: function hasOwn(o, k) { return Object.prototype.hasOwnProperty.call(Object(o), k) },
    groupBy: function groupBy(items, fn) {
        var r = Object.create(null), i = 0;
        for (var x of items) { var k = fn(x, i++); (r[k] || (r[k] = [])).push(x) }
        return r;
    },
    getOwnPropertyDescriptors: function getOwnPropertyDescriptors(o) {
        var r = {};
        for (var k of Reflect.ownKeys(o)) r[k] = Object.getOwnPropertyDescriptor(o, k);
        return r;
    },
});
def(Map, 'groupBy', function groupBy(items, fn) {
    var r = new Map(), i = 0;
    for (var x of items) { var k = fn(x, i++); if (!r.has(k)) r.set(k, []); r.get(k).push(x) }
    return r;
});

// --- Array -----------------------------------------------------------------------
defAll(Array.prototype, {
    toSorted: function toSorted(fn) { return this.slice().sort(fn) },
    toReversed: function toReversed() { return this.slice().reverse() },
    toSpliced: function toSpliced() { var a = this.slice(); a.splice.apply(a, arguments); return a },
    with: function (i, v) {
        var a = this.slice(), n = a.length;
        i = Math.trunc(i) || 0;
        if (i < 0) i += n;
        if (i < 0 || i >= n) throw new RangeError('Invalid index : ' + i);
        a[i] = v;
        return a;
    },
    copyWithin: function copyWithin(target, start, end) {
        var n = this.length;
        function at(i, d) { i = i === undefined ? d : Math.trunc(i) || 0; return i < 0 ? Math.max(n + i, 0) : Math.min(i, n) }
        var to = at(target, 0), from = at(start, 0), last = at(end, n);
        var count = Math.min(last - from, n - to);
        var copy = this.slice(from, from + count);
        for (var i = 0; i < count; i++) this[to + i] = copy[i];
        return this;
    },
});

// Array methods called on array-likes ({length, 0: ...}, strings, jQuery
// objects): the natives send those here (__arrayGenerics). Each works on a
// copy; the ones that change the array write the copy back.
function arrayCopy(o) {
    if (typeof o === 'string') return Array.from(o);
    o = Object(o);
    var n = Math.min(Math.max(Math.trunc(Number(o.length)) || 0, 0), 0x7FFFFFFF);
    var a = [];
    a.length = n;
    for (var i = 0; i < n; i++) if (i in o) a[i] = o[i];
    return a;
}
function writeBack(o, a) {
    var old = Math.trunc(Number(o.length)) || 0;
    for (var i = 0; i < a.length; i++) { if (i in a) o[i] = a[i]; else delete o[i] }
    for (; i < old; i++) delete o[i];
    o.length = a.length;
}
var generics = Object.create(null);
var AP = Array.prototype;
['at', 'concat', 'every', 'filter', 'find', 'findIndex', 'findLast', 'findLastIndex', 'flat', 'flatMap', 'forEach',
 'includes', 'indexOf', 'join', 'lastIndexOf', 'map', 'reduce', 'reduceRight', 'slice', 'some', 'toString'].forEach(function (name) {
    var f = AP[name];
    generics[name] = function () {
        if (this == null) throw new TypeError('Array.prototype.' + name + ' called on null or undefined');
        return f.apply(arrayCopy(this), arguments);
    };
});
['fill', 'pop', 'reverse', 'shift', 'sort', 'splice', 'unshift'].forEach(function (name) {
    var f = AP[name];
    var returnsThis = name === 'fill' || name === 'reverse' || name === 'sort';
    generics[name] = function () {
        if (this == null) throw new TypeError('Array.prototype.' + name + ' called on null or undefined');
        var a = arrayCopy(this), r = f.apply(a, arguments);
        writeBack(this, a);
        return returnsThis ? this : r;
    };
});
generics.push = function push() {
    var n = Math.trunc(Number(this.length)) || 0;
    for (var i = 0; i < arguments.length; i++) this[n++] = arguments[i];
    this.length = n;
    return n;
};
__arrayGenerics(generics);
delete global.__arrayGenerics;

// --- typed arrays: the list methods (the natives do the elements) -----------------
var typedKinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
var TAP = Object.getPrototypeOf(Int8Array.prototype);
function sameType(ta, values) { return new ta.constructor(values) }
defAll(TAP, {
    at: AP.at, every: AP.every, find: AP.find, findIndex: AP.findIndex, findLast: AP.findLast, findLastIndex: AP.findLastIndex,
    forEach: AP.forEach, includes: AP.includes, indexOf: AP.indexOf, lastIndexOf: AP.lastIndexOf, join: AP.join,
    reduce: AP.reduce, reduceRight: AP.reduceRight, some: AP.some, fill: AP.fill, reverse: AP.reverse, copyWithin: AP.copyWithin,
    sort: function sort(fn) { return AP.sort.call(this, fn || function (a, b) { return a - b }) },
    map: function map(fn, self) { return sameType(this, AP.map.call(this, fn, self)) },
    filter: function filter(fn, self) { return sameType(this, AP.filter.call(this, fn, self)) },
    slice: function slice(a, b) { return sameType(this, AP.slice.call(this, a, b)) },
    toReversed: function toReversed() { return sameType(this, AP.slice.call(this).reverse()) },
    toSorted: function toSorted(fn) { return sameType(this, this.slice().sort(fn)) },
    with: function (i, v) { var a = this.slice(); a[i < 0 ? i + a.length : i] = v; return a },
    toString: function toString() { return AP.join.call(this, ',') },
    toLocaleString: function toLocaleString() { return AP.join.call(this, ',') },
    keys: function* keys() { for (var i = 0; i < this.length; i++) yield i },
    values: function* values() { for (var i = 0; i < this.length; i++) yield this[i] },
    entries: function* entries() { for (var i = 0; i < this.length; i++) yield [i, this[i]] },
});
def(TAP, Symbol.iterator, TAP.values);
typedKinds.forEach(function (C) {
    var size = C.name === 'Float64Array' ? 8 : /32/.test(C.name) ? 4 : /16/.test(C.name) ? 2 : 1;
    def(C, 'BYTES_PER_ELEMENT', size);
    def(C.prototype, 'BYTES_PER_ELEMENT', size);
    Object.defineProperty(C.prototype, Symbol.toStringTag, { value: C.name, configurable: true });
    def(C, 'from', function from(src, fn, self) { var a = Array.from(src); return new C(fn ? a.map(fn, self) : a) });
    def(C, 'of', function of() { return new C(Array.prototype.slice.call(arguments)) });
});
var bytesToString = __bytesToString;
delete global.__bytesToString;
class TextEncoder {
    get encoding() { return 'utf-8' }
    encode(s) {
        s = s === undefined ? '' : String(s);
        var a = new Uint8Array(s.length);
        for (var i = 0; i < s.length; i++) a[i] = s.charCodeAt(i);
        return a;
    }
    encodeInto(s, dest) {
        var a = this.encode(s), n = Math.min(a.length, dest.length);
        for (var i = 0; i < n; i++) dest[i] = a[i];
        return { read: s.length, written: n };
    }
}
class TextDecoder {
    constructor(label, options) { this.encoding = 'utf-8'; this.fatal = !!(options && options.fatal); this.ignoreBOM = false }
    decode(bytes) {
        if (bytes === undefined) return '';
        if (!ArrayBuffer.isView(bytes) && !(bytes instanceof ArrayBuffer)) bytes = new Uint8Array(bytes);
        var s = bytesToString(bytes);
        return s.charCodeAt(0) === 0xEF && s.charCodeAt(1) === 0xBB && s.charCodeAt(2) === 0xBF ? s.slice(3) : s;
    }
}
def(global, 'TextEncoder', TextEncoder);
def(global, 'TextDecoder', TextDecoder);
def(Proxy, 'revocable', function revocable(target, handler) {
    return { proxy: new Proxy(target, handler), revoke: function () { } };
});

// --- String ----------------------------------------------------------------------
defAll(String.prototype, {
    trimLeft: String.prototype.trimStart,
    trimRight: String.prototype.trimEnd,
    substr: function substr(start, length) {
        var s = String(this), n = s.length;
        start = Math.trunc(start) || 0;
        if (start < 0) start = Math.max(n + start, 0);
        length = length === undefined ? n - start : Math.trunc(length) || 0;
        if (length <= 0) return '';
        return s.slice(start, start + length);
    },
    isWellFormed: function isWellFormed() { return true },
    toWellFormed: function toWellFormed() { return String(this) },
});
function utf8Escape(cp) {
    // a code point as %XX escapes of its UTF-8 bytes
    function hex(b) { return '%' + (b < 16 ? '0' : '') + b.toString(16) }
    if (cp < 0x80) return hex(cp);
    if (cp < 0x800) return hex(0xC0 | cp >> 6) + hex(0x80 | cp & 63);
    if (cp < 0x10000) return hex(0xE0 | cp >> 12) + hex(0x80 | cp >> 6 & 63) + hex(0x80 | cp & 63);
    return hex(0xF0 | cp >> 18) + hex(0x80 | cp >> 12 & 63) + hex(0x80 | cp >> 6 & 63) + hex(0x80 | cp & 63);
}
def(String, 'fromCodePoint', function fromCodePoint() {
    var s = '';
    for (var i = 0; i < arguments.length; i++) {
        var cp = Number(arguments[i]);
        if (!Number.isInteger(cp) || cp < 0 || cp > 0x10FFFF) throw new RangeError('Invalid code point ' + cp);
        s += cp < 0x80 ? String.fromCharCode(cp) : decodeURIComponent(utf8Escape(cp));
    }
    return s;
});

// --- Number ----------------------------------------------------------------------
// The digits of |x| as String(x) writes them: D (no leading zeros) and E, the
// power of ten of the first digit
function decimal(x) {
    var s = String(x), e = 0, m = s.indexOf('e');
    if (m >= 0) { e = Number(s.slice(m + 1)); s = s.slice(0, m) }
    var dot = s.indexOf('.');
    var ip = dot < 0 ? s : s.slice(0, dot), fp = dot < 0 ? '' : s.slice(dot + 1);
    var digits = ip + fp, lead = 0;
    while (lead < digits.length - 1 && digits[lead] === '0') lead++;
    digits = digits.slice(lead);
    var exp = ip.length - 1 - lead + e;
    digits = digits.replace(/0+$/, '') || '0';
    return { d: digits, e: exp };
}
// D rounded to n digits (half up) -> {d, e}
function roundDigits(r, n) {
    var d = r.d, e = r.e;
    if (d.length <= n) return { d: d + '0'.repeat(n - d.length), e: e };
    var keep = d.slice(0, n).split('').map(Number);
    if (Number(d[n]) >= 5) {
        var i = n - 1;
        while (i >= 0 && keep[i] === 9) { keep[i] = 0; i-- }
        if (i < 0) { keep.unshift(1); keep.pop(); e++ } else keep[i]++;
    }
    return { d: keep.join(''), e: e };
}
defAll(Number.prototype, {
    toExponential: function toExponential(f) {
        var x = Number(this);
        if (!isFinite(x)) return String(x);
        var sign = x < 0 ? '-' : '';
        var r = x === 0 ? { d: '0', e: 0 } : decimal(Math.abs(x));
        if (f !== undefined) {
            f = Math.trunc(f) || 0;
            if (f < 0 || f > 100) throw new RangeError('toExponential() argument must be between 0 and 100');
            r = roundDigits(r, f + 1);
        }
        return sign + r.d[0] + (r.d.length > 1 ? '.' + r.d.slice(1) : '') + 'e' + (r.e < 0 ? '-' : '+') + Math.abs(r.e);
    },
    toPrecision: function toPrecision(p) {
        var x = Number(this);
        if (p === undefined || !isFinite(x)) return String(x);
        p = Math.trunc(p) || 0;
        if (p < 1 || p > 100) throw new RangeError('toPrecision() argument must be between 1 and 100');
        var sign = x < 0 ? '-' : '';
        var r = roundDigits(x === 0 ? { d: '0', e: 0 } : decimal(Math.abs(x)), p);
        if (x === 0) r.e = 0;
        if (r.e < -6 || r.e >= p)
            return sign + r.d[0] + (p > 1 ? '.' + r.d.slice(1) : '') + 'e' + (r.e < 0 ? '-' : '+') + Math.abs(r.e);
        if (r.e < 0) return sign + '0.' + '0'.repeat(-r.e - 1) + r.d;
        var ip = r.d.slice(0, r.e + 1), fp = r.d.slice(r.e + 1);
        return sign + ip + (fp ? '.' + fp : '');
    },
});

// --- Promise, errors ---------------------------------------------------------------
def(Promise, 'withResolvers', function withResolvers() {
    var r = {};
    r.promise = new Promise(function (resolve, reject) { r.resolve = resolve; r.reject = reject });
    return r;
});
def(Error, 'captureStackTrace', function captureStackTrace(o) {
    if (isObject(o)) def(o, 'stack', String(o));
});
class AggregateError extends Error {
    constructor(errors, message) {
        super(message);
        def(this, 'errors', Array.from(errors));
    }
}
def(AggregateError.prototype, 'name', 'AggregateError');
def(global, 'AggregateError', AggregateError);

// --- no modules: import() fails, import.meta has the page's URL ----------------------
def(global, '__import', function (spec) {
    return Promise.reject(new TypeError('Failed to fetch dynamically imported module: ' + spec));
});
Object.defineProperty(global, '__importMeta', {
    get: function () { return { url: global.location ? String(global.location.href) : 'file:///' } },
    configurable: true, enumerable: false,
});

// --- BigInt, approximated by numbers (the lexer reads 10n as 10) ----------------------
function BigInt(v) {
    if (typeof v === 'string') v = v.trim() === '' ? 0 : Number(v);
    else if (typeof v === 'boolean') v = v ? 1 : 0;
    v = Number(v);
    if (!Number.isInteger(v)) throw new RangeError('The number ' + v + ' cannot be converted to a BigInt because it is not an integer');
    return v;
}
defAll(BigInt, {
    asUintN: function asUintN(bits, v) { var m = Math.pow(2, bits); return ((Number(v) % m) + m) % m },
    asIntN: function asIntN(bits, v) {
        var m = Math.pow(2, bits), r = ((Number(v) % m) + m) % m;
        return r >= m / 2 ? r - m : r;
    },
});
def(global, 'BigInt', BigInt);

// --- WeakRef, FinalizationRegistry (nothing is ever collected early) -----------------
class WeakRef {
    constructor(target) { def(this, ' target', target) }
    deref() { return this[' target'] }
}
class FinalizationRegistry {
    constructor(cleanup) { }
    register() { }
    unregister() { return false }
}
def(global, 'WeakRef', WeakRef);
def(global, 'FinalizationRegistry', FinalizationRegistry);

// --- structuredClone -------------------------------------------------------------
def(global, 'structuredClone', function structuredClone(value) {
    var seen = new Map();
    function copy(v) {
        if (!isObject(v)) return v;
        if (typeof v === 'function' || typeof v === 'symbol') throw new TypeError(String(v) + ' could not be cloned.');
        if (seen.has(v)) return seen.get(v);
        var r;
        if (v instanceof Date) r = new Date(v.getTime());
        else if (v instanceof RegExp) r = new RegExp(v.source, v.flags);
        else if (v instanceof Map) { r = new Map(); seen.set(v, r); v.forEach(function (val, k) { r.set(copy(k), copy(val)) }); return r }
        else if (v instanceof Set) { r = new Set(); seen.set(v, r); v.forEach(function (val) { r.add(copy(val)) }); return r }
        else if (Array.isArray(v)) { r = []; seen.set(v, r); for (var i = 0; i < v.length; i++) r[i] = copy(v[i]); return r }
        else if (v instanceof Error) { r = new Error(v.message); r.name = v.name }
        else r = {};
        seen.set(v, r);
        for (var k of Object.keys(v)) r[k] = copy(v[k]);
        return r;
    }
    return copy(value);
});

// --- Events (EventTarget; the browser's DOM builds on these) ---------------------
class Event {
    constructor(type, init) {
        if (arguments.length === 0) throw new TypeError("Failed to construct 'Event': 1 argument required, but only 0 present.");
        init = init || {};
        this.type = String(type);
        this.bubbles = !!init.bubbles;
        this.cancelable = !!init.cancelable;
        this.composed = !!init.composed;
        this.defaultPrevented = false;
        this.isTrusted = false;
        this.target = null;
        this.currentTarget = null;
        this.eventPhase = 0;
        this.timeStamp = typeof performance === 'object' ? performance.now() : 0;
    }
    preventDefault() { if (this.cancelable) this.defaultPrevented = true }
    stopPropagation() { def(this, ' stop', true) }
    stopImmediatePropagation() { def(this, ' stop', true); def(this, ' stopNow', true) }
    composedPath() { return this.target ? [this.target] : [] }
    initEvent(type, bubbles, cancelable) {
        this.type = String(type); this.bubbles = !!bubbles; this.cancelable = !!cancelable;
    }
    get returnValue() { return !this.defaultPrevented }
    get cancelBubble() { return !!this[' stop'] }
    set cancelBubble(v) { if (v) this.stopPropagation() }
}
Event.NONE = 0; Event.CAPTURING_PHASE = 1; Event.AT_TARGET = 2; Event.BUBBLING_PHASE = 3;
class CustomEvent extends Event {
    constructor(type, init) {
        super(type, init);
        this.detail = init && init.detail !== undefined ? init.detail : null;
    }
    initCustomEvent(type, bubbles, cancelable, detail) { this.initEvent(type, bubbles, cancelable); this.detail = detail }
}
// listeners: {type: [{fn, once, capture}]} in a hidden property
function listenerMap(target) {
    var m = target[' jsListeners'];
    if (!m) { m = Object.create(null); def(target, ' jsListeners', m) }
    return m;
}
function captureOf(options) { return typeof options === 'boolean' ? options : !!(options && options.capture) }
class EventTarget {
    addEventListener(type, fn, options) {
        if (fn == null) return;
        var list = listenerMap(this)[type] || (listenerMap(this)[type] = []);
        var capture = captureOf(options);
        for (var l of list) if (l.fn === fn && l.capture === capture) return;
        list.push({ fn: fn, capture: capture, once: !!(options && options.once) });
        if (options && options.signal) {
            var self = this;
            options.signal.addEventListener('abort', function () { self.removeEventListener(type, fn, options) });
        }
    }
    removeEventListener(type, fn, options) {
        var list = listenerMap(this)[type];
        if (!list) return;
        var capture = captureOf(options);
        for (var i = 0; i < list.length; i++)
            if (list[i].fn === fn && list[i].capture === capture) { list.splice(i, 1); return }
    }
    dispatchEvent(event) {
        event.target = this;
        event.currentTarget = this;
        event.eventPhase = 2;
        var list = (listenerMap(this)[event.type] || []).slice();
        for (var l of list) {
            if (l.once) this.removeEventListener(event.type, l.fn, l);
            try {
                if (typeof l.fn === 'function') l.fn.call(this, event); else l.fn.handleEvent(event);
            } catch (e) { reportError(e) }
            if (event[' stopNow']) break;
        }
        var handler = this['on' + event.type];
        if (typeof handler === 'function' && !event[' stopNow']) {
            try { if (handler.call(this, event) === false) event.defaultPrevented = true } catch (e) { reportError(e) }
        }
        event.currentTarget = null;
        event.eventPhase = 0;
        return !event.defaultPrevented;
    }
}
function reportError(e) {
    console.log('Uncaught ' + (e && e.stack ? e.stack : String(e)));
}
def(global, 'reportError', reportError);
def(global, 'Event', Event);
def(global, 'CustomEvent', CustomEvent);
def(global, 'EventTarget', EventTarget);

// --- AbortController -------------------------------------------------------------
class AbortSignal extends EventTarget {
    constructor() { super(); this.aborted = false; this.reason = undefined; this.onabort = null }
    throwIfAborted() { if (this.aborted) throw this.reason }
    static abort(reason) { var c = new AbortController(); c.abort(reason); return c.signal }
    static timeout(ms) {
        var c = new AbortController();
        setTimeout(function () { c.abort(new Error('signal timed out')) }, ms);
        return c.signal;
    }
    static any(signals) {
        var c = new AbortController();
        for (var s of signals) {
            if (s.aborted) { c.abort(s.reason); break }
            s.addEventListener('abort', function () { c.abort(this.reason) });
        }
        return c.signal;
    }
}
class AbortController {
    constructor() { this.signal = new AbortSignal() }
    abort(reason) {
        var s = this.signal;
        if (s.aborted) return;
        s.aborted = true;
        s.reason = reason === undefined ? new Error('This operation was aborted') : reason;
        if (reason === undefined) s.reason.name = 'AbortError';
        s.dispatchEvent(new Event('abort'));
    }
}
def(global, 'AbortSignal', AbortSignal);
def(global, 'AbortController', AbortController);

// --- URLSearchParams, URL ------------------------------------------------------------
function formEncode(s) { return encodeURIComponent(s).replace(/%20/g, '+') }
function formDecode(s) {
    s = s.replace(/\+/g, ' ');
    try { return decodeURIComponent(s) } catch (e) { return s }
}
class URLSearchParams {
    constructor(init) {
        def(this, ' list', []);
        def(this, ' url', null);
        if (init == null) return;
        if (typeof init === 'object') {
            if (typeof init[Symbol.iterator] === 'function') {
                for (var pair of init) this.append(pair[0], pair[1]);
            } else {
                for (var k of Object.keys(init)) this.append(k, init[k]);
            }
        } else this[' parse'](String(init));
    }
    [' parse'](s) {
        var list = this[' list'];
        list.length = 0;
        if (s[0] === '?') s = s.slice(1);
        for (var part of s.split('&')) {
            if (!part) continue;
            var eq = part.indexOf('=');
            list.push(eq < 0 ? [formDecode(part), ''] : [formDecode(part.slice(0, eq)), formDecode(part.slice(eq + 1))]);
        }
    }
    [' changed']() {
        var url = this[' url'];
        if (url) { var q = this.toString(); url[' parts'].search = q ? '?' + q : '' }
    }
    append(k, v) { this[' list'].push([String(k), String(v)]); this[' changed']() }
    delete(k, v) {
        k = String(k);
        def(this, ' list', this[' list'].filter(function (p) { return p[0] !== k || (v !== undefined && p[1] !== String(v)) }));
        this[' changed']();
    }
    get(k) { k = String(k); for (var p of this[' list']) if (p[0] === k) return p[1]; return null }
    getAll(k) { k = String(k); return this[' list'].filter(function (p) { return p[0] === k }).map(function (p) { return p[1] }) }
    has(k, v) { k = String(k); return this[' list'].some(function (p) { return p[0] === k && (v === undefined || p[1] === String(v)) }) }
    set(k, v) {
        k = String(k); v = String(v);
        var list = this[' list'], found = false, out = [];
        for (var p of list) {
            if (p[0] !== k) out.push(p);
            else if (!found) { out.push([k, v]); found = true }
        }
        if (!found) out.push([k, v]);
        def(this, ' list', out);
        this[' changed']();
    }
    sort() { this[' list'].sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0 }); this[' changed']() }
    forEach(fn, self) { for (var p of this[' list']) fn.call(self, p[1], p[0], this) }
    keys() { return this[' list'].map(function (p) { return p[0] })[Symbol.iterator]() }
    values() { return this[' list'].map(function (p) { return p[1] })[Symbol.iterator]() }
    entries() { return this[' list'].map(function (p) { return [p[0], p[1]] })[Symbol.iterator]() }
    [Symbol.iterator]() { return this.entries() }
    get size() { return this[' list'].length }
    toString() { return this[' list'].map(function (p) { return formEncode(p[0]) + '=' + formEncode(p[1]) }).join('&') }
}
def(URLSearchParams.prototype, Symbol.toStringTag, 'URLSearchParams');

var defaultPorts = { 'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443', 'ftp:': '21' };
// scheme://user:pass@host:port/path?query#hash -> its parts, or null
function parseURL(s) {
    var m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(\/\/([^\/?#]*))?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(s);
    if (!m) return null;
    var p = { protocol: m[1].toLowerCase(), username: '', password: '', hostname: '', port: '',
              pathname: m[4] || '', search: m[5] && m[5] !== '?' ? m[5] : '', hash: m[6] && m[6] !== '#' ? m[6] : '',
              special: m[2] !== undefined };
    if (m[2] !== undefined) {
        var auth = m[3], at = auth.lastIndexOf('@');
        if (at >= 0) {
            var cred = auth.slice(0, at), colon = cred.indexOf(':');
            p.username = colon < 0 ? cred : cred.slice(0, colon);
            p.password = colon < 0 ? '' : cred.slice(colon + 1);
            auth = auth.slice(at + 1);
        }
        var pm = /^(\[[^\]]*\]|[^:]*)(:(\d*))?$/.exec(auth);
        if (!pm) return null;
        p.hostname = pm[1].toLowerCase();
        p.port = pm[3] || '';
        if (p.port === defaultPorts[p.protocol]) p.port = '';
        if (!p.pathname) p.pathname = '/';
    }
    p.pathname = normalizePath(p.pathname, p.special);
    return p;
}
function normalizePath(path, special) {
    if (!special || path[0] !== '/') return path;
    var out = [];
    var parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
        var seg = parts[i];
        if (seg === '..') { out.pop(); if (i === parts.length - 1) out.push('') }
        else if (seg === '.') { if (i === parts.length - 1) out.push('') }
        else out.push(seg);
    }
    return '/' + out.join('/');
}
function resolveURL(rel, base) {
    rel = String(rel).trim();
    var abs = parseURL(rel);
    if (abs) return abs;
    var b = parseURL(String(base));
    if (!b) return null;
    var p = Object.assign({}, b);
    p.hash = '';
    if (rel.slice(0, 2) === '//') return parseURL(b.protocol + rel);
    var m = /^([^?#]*)(\?[^#]*)?(#.*)?$/.exec(rel);
    var path = m[1], search = m[2] || '', hash = m[3] || '';
    if (path) {
        p.pathname = normalizePath(path[0] === '/' ? path : b.pathname.replace(/[^\/]*$/, '') + path, true);
        p.search = search;
    } else if (search) p.search = search;
    if (search === '?') p.search = '';
    p.hash = hash === '#' ? '' : hash;
    return p;
}
class URL {
    constructor(url, base) {
        var p = base === undefined ? parseURL(String(url).trim()) : resolveURL(url, base);
        if (!p) throw new TypeError("Failed to construct 'URL': Invalid URL");
        def(this, ' parts', p);
        var params = new URLSearchParams(p.search);
        def(params, ' url', this);
        def(this, ' params', params);
    }
    static canParse(url, base) { try { new URL(url, base); return true } catch (e) { return false } }
    static parse(url, base) { try { return new URL(url, base) } catch (e) { return null } }
    get protocol() { return this[' parts'].protocol }
    set protocol(v) { v = String(v); if (v.slice(-1) !== ':') v += ':'; this[' parts'].protocol = v.toLowerCase() }
    get username() { return this[' parts'].username }
    set username(v) { this[' parts'].username = String(v) }
    get password() { return this[' parts'].password }
    set password(v) { this[' parts'].password = String(v) }
    get hostname() { return this[' parts'].hostname }
    set hostname(v) { this[' parts'].hostname = String(v).toLowerCase() }
    get port() { return this[' parts'].port }
    set port(v) { v = String(v); this[' parts'].port = v === defaultPorts[this.protocol] ? '' : v }
    get host() { var p = this[' parts']; return p.hostname + (p.port ? ':' + p.port : '') }
    set host(v) {
        var m = /^([^:]*)(:(\d*))?$/.exec(String(v));
        if (m) { this.hostname = m[1]; this.port = m[3] || '' }
    }
    get origin() {
        var p = this[' parts'];
        return p.special && p.hostname ? p.protocol + '//' + this.host : 'null';
    }
    get pathname() { return this[' parts'].pathname }
    set pathname(v) {
        v = String(v);
        var p = this[' parts'];
        if (p.special && v[0] !== '/') v = '/' + v;
        p.pathname = normalizePath(v, p.special);
    }
    get search() { return this[' parts'].search }
    set search(v) {
        v = String(v);
        if (v && v[0] !== '?') v = '?' + v;
        this[' parts'].search = v === '?' ? '' : v;
        this[' params'][' parse'](v);
    }
    get searchParams() { return this[' params'] }
    get hash() { return this[' parts'].hash }
    set hash(v) { v = String(v); if (v && v[0] !== '#') v = '#' + v; this[' parts'].hash = v === '#' ? '' : v }
    get href() {
        var p = this[' parts'], auth = '';
        if (p.username || p.password) auth = p.username + (p.password ? ':' + p.password : '') + '@';
        return p.protocol + (p.special ? '//' + auth + this.host : '') + p.pathname + p.search + p.hash;
    }
    set href(v) {
        var p = parseURL(String(v));
        if (!p) throw new TypeError("Failed to set the 'href' property on 'URL': Invalid URL");
        def(this, ' parts', p);
        this[' params'][' parse'](p.search);
    }
    toString() { return this.href }
    toJSON() { return this.href }
    static createObjectURL() { return 'blob:null/0' }
    static revokeObjectURL() { }
}
def(URL.prototype, Symbol.toStringTag, 'URL');
def(global, 'URLSearchParams', URLSearchParams);
def(global, 'URL', URL);

// --- Intl (English, UTC) -----------------------------------------------------------
var monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
var dayNames = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
function group3(s) { return s.replace(/\B(?=(\d{3})+(?!\d))/g, ',') }
class NumberFormat {
    constructor(locales, options) {
        var o = options || {};
        this[' o'] = {
            locale: 'en-US', numberingSystem: 'latn', style: o.style || 'decimal', currency: o.currency,
            currencyDisplay: o.currencyDisplay || 'symbol', useGrouping: o.useGrouping !== false,
            notation: o.notation || 'standard', unit: o.unit, signDisplay: o.signDisplay || 'auto',
            minimumIntegerDigits: o.minimumIntegerDigits || 1,
            minimumFractionDigits: o.minimumFractionDigits, maximumFractionDigits: o.maximumFractionDigits,
            maximumSignificantDigits: o.maximumSignificantDigits,
        };
        var r = this[' o'];
        var dflt = r.style === 'currency' ? 2 : 0;
        if (r.minimumFractionDigits === undefined) r.minimumFractionDigits = Math.min(dflt, r.maximumFractionDigits === undefined ? dflt : r.maximumFractionDigits);
        if (r.maximumFractionDigits === undefined) r.maximumFractionDigits = Math.max(r.minimumFractionDigits, r.style === 'currency' ? 2 : r.style === 'percent' ? 0 : 3);
        def(this, 'format', this.format.bind(this));
    }
    format(n) {
        var o = this[' o'];
        n = Number(n);
        if (isNaN(n)) return 'NaN';
        if (o.style === 'percent') n *= 100;
        var neg = n < 0 || Object.is(n, -0) && o.signDisplay === 'negative';
        n = Math.abs(n);
        if (!isFinite(n)) return (neg ? '-' : '') + '∞';
        var suffix = '';
        if (o.notation === 'compact') {
            var units = [[1e12, 'T'], [1e9, 'B'], [1e6, 'M'], [1e3, 'K']];
            for (var u of units) if (n >= u[0]) { n = n / u[0]; suffix = u[1]; break }
            n = Number(n.toPrecision(n < 100 ? 2 : 3));
        }
        var s;
        if (o.maximumSignificantDigits) s = String(Number(n.toPrecision(o.maximumSignificantDigits)));
        else {
            s = n.toFixed(o.maximumFractionDigits);
            if (s.indexOf('.') >= 0) {
                var min = o.minimumFractionDigits;
                var parts = s.split('.'), frac = parts[1];
                while (frac.length > min && frac[frac.length - 1] === '0') frac = frac.slice(0, -1);
                s = parts[0] + (frac ? '.' + frac : '');
            }
        }
        var ip = s.split('.')[0], fp = s.split('.')[1];
        while (ip.length < o.minimumIntegerDigits) ip = '0' + ip;
        if (o.useGrouping) ip = group3(ip);
        s = ip + (fp ? '.' + fp : '') + suffix;
        if (o.style === 'percent') s += '%';
        if (o.style === 'currency') {
            var symbols = { USD: '$', EUR: '€', GBP: '£', JPY: '¥', INR: '₹', CAD: 'CA$', AUD: 'A$' };
            var sym = o.currencyDisplay === 'code' ? o.currency + ' ' : symbols[o.currency] || (o.currency + ' ');
            s = sym + s;
        }
        if (o.style === 'unit' && o.unit) s += ' ' + o.unit;
        return (neg ? '-' : o.signDisplay === 'always' || o.signDisplay === 'exceptZero' && n !== 0 ? '+' : '') + s;
    }
    formatToParts(n) { return [{ type: 'literal', value: this.format(n) }] }
    resolvedOptions() { return Object.assign({}, this[' o']) }
    static supportedLocalesOf(l) { return ['en-US'] }
}
function pad2(n) { return n < 10 ? '0' + n : String(n) }
class DateTimeFormat {
    constructor(locales, options) {
        var o = Object.assign({}, options || {});
        if (!o.weekday && !o.year && !o.month && !o.day && !o.hour && !o.minute && !o.second && !o.dateStyle && !o.timeStyle) {
            o.year = 'numeric'; o.month = 'numeric'; o.day = 'numeric';
        }
        if (o.dateStyle === 'full') { o.weekday = 'long'; o.month = 'long'; o.day = 'numeric'; o.year = 'numeric' }
        else if (o.dateStyle === 'long') { o.month = 'long'; o.day = 'numeric'; o.year = 'numeric' }
        else if (o.dateStyle === 'medium') { o.month = 'short'; o.day = 'numeric'; o.year = 'numeric' }
        else if (o.dateStyle === 'short') { o.month = 'numeric'; o.day = 'numeric'; o.year = '2-digit' }
        if (o.timeStyle) { o.hour = 'numeric'; o.minute = '2-digit'; if (o.timeStyle !== 'short') o.second = '2-digit' }
        o.locale = 'en-US'; o.calendar = 'gregory'; o.numberingSystem = 'latn'; o.timeZone = o.timeZone || 'UTC';
        this[' o'] = o;
        def(this, 'format', this.format.bind(this));
    }
    formatToParts(d) {
        var o = this[' o'];
        d = d === undefined ? new Date() : new Date(d);
        if (isNaN(d.getTime())) throw new RangeError('Invalid time value');
        var parts = [];
        function add(type, value) {
            if (parts.length) parts.push({ type: 'literal', value: type === 'hour' ? ', ' : ' ' });
            parts.push({ type: type, value: value });
        }
        var named = o.month === 'long' || o.month === 'short';
        if (o.weekday) add('weekday', o.weekday === 'long' ? dayNames[d.getUTCDay()] : dayNames[d.getUTCDay()].slice(0, 3));
        if (named) {
            if (o.weekday) parts.push({ type: 'literal', value: ',' });
            if (o.month) add('month', o.month === 'long' ? monthNames[d.getUTCMonth()] : monthNames[d.getUTCMonth()].slice(0, 3));
            if (o.day) add('day', String(d.getUTCDate()));
            if (o.year) { if (o.day) parts.push({ type: 'literal', value: ',' }); add('year', String(d.getUTCFullYear())) }
        } else if (o.month || o.day || o.year) {
            var ds = [];
            if (o.month) ds.push(o.month === '2-digit' ? pad2(d.getUTCMonth() + 1) : String(d.getUTCMonth() + 1));
            if (o.day) ds.push(o.day === '2-digit' ? pad2(d.getUTCDate()) : String(d.getUTCDate()));
            if (o.year) ds.push(o.year === '2-digit' ? pad2(d.getUTCFullYear() % 100) : String(d.getUTCFullYear()));
            if (parts.length) parts.push({ type: 'literal', value: ', ' });
            parts.push({ type: 'literal', value: ds.join('/') });
        }
        if (o.hour || o.minute || o.second) {
            var h = d.getUTCHours(), h12 = o.hour12 !== false && o.hourCycle !== 'h23';
            var ts = [];
            if (o.hour) ts.push(h12 ? String(h % 12 || 12) : o.hour === '2-digit' ? pad2(h) : String(h));
            if (o.minute) ts.push(pad2(d.getUTCMinutes()));
            if (o.second) ts.push(pad2(d.getUTCSeconds()));
            var t = ts.join(':') + (h12 && o.hour ? (h < 12 ? ' AM' : ' PM') : '');
            if (parts.length) parts.push({ type: 'literal', value: ', ' });
            parts.push({ type: 'literal', value: t });
        }
        return parts;
    }
    format(d) { return this.formatToParts(d).map(function (p) { return p.value }).join('') }
    formatRange(a, b) { return this.format(a) + ' – ' + this.format(b) }
    resolvedOptions() { return Object.assign({}, this[' o']) }
    static supportedLocalesOf(l) { return ['en-US'] }
}
class PluralRules {
    constructor(locales, options) { this[' type'] = options && options.type || 'cardinal' }
    select(n) {
        n = Number(n);
        if (this[' type'] === 'ordinal') {
            var m10 = n % 10, m100 = n % 100;
            if (m10 === 1 && m100 !== 11) return 'one';
            if (m10 === 2 && m100 !== 12) return 'two';
            if (m10 === 3 && m100 !== 13) return 'few';
            return 'other';
        }
        return n === 1 ? 'one' : 'other';
    }
    resolvedOptions() { return { locale: 'en-US', type: this[' type'] } }
    static supportedLocalesOf(l) { return ['en-US'] }
}
class Collator {
    constructor(locales, options) {
        var o = options || {};
        this[' o'] = { locale: 'en-US', sensitivity: o.sensitivity || 'variant', numeric: !!o.numeric };
        def(this, 'compare', this.compare.bind(this));
    }
    compare(a, b) {
        a = String(a); b = String(b);
        var o = this[' o'];
        if (o.sensitivity === 'base' || o.sensitivity === 'accent') { a = a.toLowerCase(); b = b.toLowerCase() }
        if (o.numeric) {
            var re = /(\d+|\D+)/g, x = a.match(re) || [], y = b.match(re) || [];
            for (var i = 0; i < Math.min(x.length, y.length); i++) {
                var c = /^\d/.test(x[i]) && /^\d/.test(y[i]) ? Number(x[i]) - Number(y[i]) : x[i].localeCompare(y[i]);
                if (c) return c < 0 ? -1 : 1;
            }
            return x.length - y.length < 0 ? -1 : x.length > y.length ? 1 : 0;
        }
        return a.localeCompare(b);
    }
    resolvedOptions() { return Object.assign({}, this[' o']) }
    static supportedLocalesOf(l) { return ['en-US'] }
}
class RelativeTimeFormat {
    constructor(locales, options) { this[' numeric'] = options && options.numeric || 'always' }
    format(v, unit) {
        v = Number(v);
        unit = String(unit).replace(/s$/, '');
        if (this[' numeric'] === 'auto') {
            if (unit === 'day' && v === 0) return 'today';
            if (unit === 'day' && v === 1) return 'tomorrow';
            if (unit === 'day' && v === -1) return 'yesterday';
            if (v === 0) return 'this ' + unit;
        }
        var n = Math.abs(v), words = n + ' ' + unit + (n === 1 ? '' : 's');
        return v < 0 || Object.is(v, -0) ? words + ' ago' : 'in ' + words;
    }
    resolvedOptions() { return { locale: 'en-US', numeric: this[' numeric'], style: 'long' } }
}
class ListFormat {
    constructor(locales, options) { this[' type'] = options && options.type === 'disjunction' ? 'or' : 'and' }
    format(list) {
        var a = Array.from(list, String);
        if (a.length < 2) return a.join('');
        if (a.length === 2) return a[0] + ' ' + this[' type'] + ' ' + a[1];
        return a.slice(0, -1).join(', ') + ', ' + this[' type'] + ' ' + a[a.length - 1];
    }
}
class Segmenter {
    constructor(locales, options) { this[' g'] = options && options.granularity || 'grapheme' }
    segment(s) {
        s = String(s);
        var re = this[' g'] === 'word' ? /\w+|\W/g : this[' g'] === 'sentence' ? /[^.!?]+[.!?]*\s*/g : /[\s\S]/g;
        var out = [], m;
        while ((m = re.exec(s))) out.push({ segment: m[0], index: m.index, input: s, isWordLike: /\w/.test(m[0]) });
        return out;
    }
}
var Intl = {};
defAll(Intl, {
    NumberFormat: NumberFormat, DateTimeFormat: DateTimeFormat, PluralRules: PluralRules, Collator: Collator,
    RelativeTimeFormat: RelativeTimeFormat, ListFormat: ListFormat, Segmenter: Segmenter,
    getCanonicalLocales: function getCanonicalLocales(l) { return l === undefined ? [] : [].concat(l) },
    supportedValuesOf: function supportedValuesOf() { return [] },
});
def(Intl, Symbol.toStringTag, 'Intl');
def(global, 'Intl', Intl);
def(Number.prototype, 'toLocaleString', function toLocaleString(locales, options) {
    return new NumberFormat(locales, options).format(this);
});
defAll(Date.prototype, {
    toLocaleDateString: function toLocaleDateString(l, o) {
        return new DateTimeFormat(l, o || { year: 'numeric', month: 'numeric', day: 'numeric' }).format(this);
    },
    toLocaleTimeString: function toLocaleTimeString(l, o) {
        return new DateTimeFormat(l, o || { hour: 'numeric', minute: '2-digit', second: '2-digit' }).format(this);
    },
    toLocaleString: function toLocaleString(l, o) {
        return new DateTimeFormat(l, o || { year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit', second: '2-digit' }).format(this);
    },
});

})(globalThis);
