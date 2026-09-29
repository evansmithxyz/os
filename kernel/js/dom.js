// Antigravity OS - the browser's DOM classes and the smaller web APIs, written
// in JavaScript on top of the native DOM (kernel/js/jsdom.asm). Every page's
// realm runs this right after jsd_init, before the page's own scripts.
(function (global) {
'use strict';

var setProtos = global.__domProtos;
delete global.__domProtos;
var pageScript = global.__currentScript;
delete global.__currentScript;
var formSubmit = global.__formSubmit;
delete global.__formSubmit;
var natives = setProtos();
var nodeProto = natives[0], nativeEventProto = natives[1];
var document = global.document;

function def(obj, name, value) {
    Object.defineProperty(obj, name, { value: value, writable: true, configurable: true, enumerable: false });
}
function defAll(obj, props) {
    for (var k of Object.keys(props)) def(obj, k, props[k]);
}
function getter(obj, name, get, set) {
    Object.defineProperty(obj, name, { get: get, set: set || function () { }, configurable: true, enumerable: false });
}

// --- the classes ---------------------------------------------------------------------
// klass(name, parent, proto): a constructor that cannot be called (as in
// browsers), its prototype chained to the parent's
function klass(name, parent, proto) {
    var C = function () { throw new TypeError('Illegal constructor') };
    Object.defineProperty(C, 'name', { value: name, configurable: true });
    proto = proto || Object.create(parent ? parent.prototype : Object.prototype);
    if (parent) {
        if (Object.getPrototypeOf(proto) !== parent.prototype) Object.setPrototypeOf(proto, parent.prototype);
        Object.setPrototypeOf(C, parent);
    }
    def(C, 'prototype', proto);
    def(proto, 'constructor', C);
    Object.defineProperty(proto, Symbol.toStringTag, { value: name, configurable: true });
    def(global, name, C);
    return C;
}
var EventTarget = global.EventTarget;
var Node = klass('Node', EventTarget, nodeProto);
var Element = klass('Element', Node);
var HTMLElement = klass('HTMLElement', Element);
var SVGElement = klass('SVGElement', Element);
klass('SVGGraphicsElement', SVGElement);
var CharacterData = klass('CharacterData', Node);
var Text = klass('Text', CharacterData);
var Comment = klass('Comment', CharacterData);
var Document = klass('Document', Node);
var HTMLDocument = klass('HTMLDocument', Document);
var DocumentFragment = klass('DocumentFragment', Node);
klass('ShadowRoot', DocumentFragment);
var Attr = klass('Attr', Node);

var nodeTypes = { ELEMENT_NODE: 1, ATTRIBUTE_NODE: 2, TEXT_NODE: 3, CDATA_SECTION_NODE: 4, PROCESSING_INSTRUCTION_NODE: 7,
    COMMENT_NODE: 8, DOCUMENT_NODE: 9, DOCUMENT_TYPE_NODE: 10, DOCUMENT_FRAGMENT_NODE: 11,
    DOCUMENT_POSITION_DISCONNECTED: 1, DOCUMENT_POSITION_PRECEDING: 2, DOCUMENT_POSITION_FOLLOWING: 4,
    DOCUMENT_POSITION_CONTAINS: 8, DOCUMENT_POSITION_CONTAINED_BY: 16 };
for (var k of Object.keys(nodeTypes)) { def(Node, k, nodeTypes[k]); def(nodeProto, k, nodeTypes[k]) }

// elements' classes by tag name
var tagClasses = {
    HTMLHtmlElement: 'html', HTMLHeadElement: 'head', HTMLBodyElement: 'body', HTMLDivElement: 'div',
    HTMLSpanElement: 'span', HTMLParagraphElement: 'p', HTMLHeadingElement: 'h1 h2 h3 h4 h5 h6',
    HTMLAnchorElement: 'a', HTMLImageElement: 'img', HTMLInputElement: 'input', HTMLButtonElement: 'button',
    HTMLFormElement: 'form', HTMLSelectElement: 'select', HTMLOptionElement: 'option', HTMLOptGroupElement: 'optgroup',
    HTMLTextAreaElement: 'textarea', HTMLLabelElement: 'label', HTMLFieldSetElement: 'fieldset', HTMLLegendElement: 'legend',
    HTMLUListElement: 'ul', HTMLOListElement: 'ol', HTMLLIElement: 'li', HTMLDListElement: 'dl',
    HTMLTableElement: 'table', HTMLTableRowElement: 'tr', HTMLTableCellElement: 'td th',
    HTMLTableSectionElement: 'thead tbody tfoot', HTMLTableCaptionElement: 'caption', HTMLTableColElement: 'col colgroup',
    HTMLScriptElement: 'script', HTMLStyleElement: 'style', HTMLLinkElement: 'link', HTMLMetaElement: 'meta',
    HTMLTitleElement: 'title', HTMLBaseElement: 'base', HTMLIFrameElement: 'iframe', HTMLCanvasElement: 'canvas',
    HTMLTemplateElement: 'template', HTMLPreElement: 'pre', HTMLBRElement: 'br', HTMLHRElement: 'hr',
    HTMLSourceElement: 'source', HTMLDetailsElement: 'details', HTMLDialogElement: 'dialog', HTMLSlotElement: 'slot',
    HTMLPictureElement: 'picture', HTMLQuoteElement: 'blockquote q', HTMLModElement: 'ins del', HTMLMapElement: 'map',
    HTMLAreaElement: 'area', HTMLObjectElement: 'object', HTMLEmbedElement: 'embed', HTMLProgressElement: 'progress',
    HTMLMeterElement: 'meter', HTMLOutputElement: 'output', HTMLDataListElement: 'datalist', HTMLTimeElement: 'time',
    HTMLTrackElement: 'track', HTMLMenuElement: 'menu', HTMLUnknownElement: '',
};
var tagProtos = Object.create(null);
for (var name of Object.keys(tagClasses)) {
    var C = klass(name, HTMLElement);
    for (var tag of tagClasses[name].split(' ')) if (tag) tagProtos[tag] = C.prototype;
}
var HTMLMediaElement = klass('HTMLMediaElement', HTMLElement);
tagProtos.video = klass('HTMLVideoElement', HTMLMediaElement).prototype;
tagProtos.audio = klass('HTMLAudioElement', HTMLMediaElement).prototype;
tagProtos['#document-fragment'] = DocumentFragment.prototype;
var svgTags = 'svg g path circle ellipse line polyline polygon rect text tspan defs use symbol clippath mask pattern image lineargradient radialgradient stop foreignobject title desc marker filter';
for (var tag of svgTags.split(' ')) tagProtos[tag] = SVGElement.prototype;
tagProtos.svg = klass('SVGSVGElement', SVGElement).prototype;
setProtos(tagProtos, HTMLElement.prototype, Text.prototype, Comment.prototype, DocumentFragment.prototype, HTMLDocument.prototype);
Object.setPrototypeOf(document, HTMLDocument.prototype);

// window
var Window = klass('Window', EventTarget);
def(Window, Symbol.hasInstance, function (o) { return o === global });

// events: the native ones (clicks, load) are Events too
var Event = global.Event;
Object.setPrototypeOf(nativeEventProto, Event.prototype);
function eventClass(name, parent, fields) {
    var C = class extends parent {
        constructor(type, init) {
            super(type, init);
            init = init || {};
            for (var f of Object.keys(fields)) this[f] = init[f] !== undefined ? init[f] : fields[f];
        }
    };
    Object.defineProperty(C, 'name', { value: name, configurable: true });
    Object.defineProperty(C.prototype, Symbol.toStringTag, { value: name, configurable: true });
    def(global, name, C);
    return C;
}
var UIEvent = eventClass('UIEvent', Event, { view: null, detail: 0 });
var mouseFields = { screenX: 0, screenY: 0, clientX: 0, clientY: 0, pageX: 0, pageY: 0, offsetX: 0, offsetY: 0,
    ctrlKey: false, shiftKey: false, altKey: false, metaKey: false, button: 0, buttons: 0, relatedTarget: null };
var MouseEvent = eventClass('MouseEvent', UIEvent, mouseFields);
eventClass('PointerEvent', MouseEvent, { pointerId: 1, pointerType: 'mouse', isPrimary: true, width: 1, height: 1, pressure: 0 });
eventClass('WheelEvent', MouseEvent, { deltaX: 0, deltaY: 0, deltaZ: 0, deltaMode: 0 });
eventClass('DragEvent', MouseEvent, { dataTransfer: null });
eventClass('KeyboardEvent', UIEvent, { key: '', code: '', keyCode: 0, charCode: 0, which: 0, location: 0, repeat: false,
    isComposing: false, ctrlKey: false, shiftKey: false, altKey: false, metaKey: false });
eventClass('FocusEvent', UIEvent, { relatedTarget: null });
eventClass('InputEvent', UIEvent, { data: null, inputType: '', isComposing: false });
eventClass('CompositionEvent', UIEvent, { data: '' });
eventClass('TouchEvent', UIEvent, { touches: [], targetTouches: [], changedTouches: [] });
eventClass('ErrorEvent', Event, { message: '', filename: '', lineno: 0, colno: 0, error: null });
eventClass('MessageEvent', Event, { data: null, origin: '', lastEventId: '', source: null, ports: [] });
eventClass('ProgressEvent', Event, { lengthComputable: false, loaded: 0, total: 0 });
eventClass('PopStateEvent', Event, { state: null });
eventClass('HashChangeEvent', Event, { oldURL: '', newURL: '' });
eventClass('PageTransitionEvent', Event, { persisted: false });
eventClass('SubmitEvent', Event, { submitter: null });
eventClass('AnimationEvent', Event, { animationName: '', elapsedTime: 0, pseudoElement: '' });
eventClass('TransitionEvent', Event, { propertyName: '', elapsedTime: 0, pseudoElement: '' });
eventClass('StorageEvent', Event, { key: null, oldValue: null, newValue: null, url: '', storageArea: null });
eventClass('PromiseRejectionEvent', Event, { promise: null, reason: undefined });

// --- listeners: options (once, signal) and objects with handleEvent -------------------
var wrappers = new WeakMap();           // listener -> [{target, type, fn}]
function wrapAdd(add) {
    return function addEventListener(type, listener, options) {
        var self = this == null ? global : this;
        if (listener == null || typeof listener !== 'function' && typeof listener !== 'object') return;
        type = String(type);
        var once = !!(options && typeof options === 'object' && options.once);
        var fn = listener;
        if (typeof listener !== 'function' || once) {
            var list = wrappers.get(listener);
            if (!list) { list = []; wrappers.set(listener, list) }
            for (var w of list) if (w.target === self && w.type === type) return;
            fn = function (e) {
                if (once) self.removeEventListener(type, listener);
                return typeof listener === 'function' ? listener.call(this, e) : listener.handleEvent(e);
            };
            list.push({ target: self, type: type, fn: fn });
        }
        add.call(self, type, fn);
        if (options && typeof options === 'object' && options.signal) {
            options.signal.addEventListener('abort', function () { self.removeEventListener(type, listener) });
        }
    };
}
function wrapRemove(remove) {
    return function removeEventListener(type, listener) {
        var self = this == null ? global : this;
        type = String(type);
        var list = listener != null && typeof listener !== 'string' && wrappers.get(listener);
        if (list) {
            for (var i = 0; i < list.length; i++) {
                if (list[i].target === self && list[i].type === type) {
                    remove.call(self, type, list[i].fn);
                    list.splice(i, 1);
                    return;
                }
            }
        }
        remove.call(self, type, listener);
    };
}
def(nodeProto, 'addEventListener', wrapAdd(nodeProto.addEventListener));
def(nodeProto, 'removeEventListener', wrapRemove(nodeProto.removeEventListener));
def(global, 'addEventListener', wrapAdd(global.addEventListener));
def(global, 'removeEventListener', wrapRemove(global.removeEventListener));

// --- inserting nodes: fragments give their children; strings become text --------------
var nativeAppendChild = nodeProto.appendChild, nativeInsertBefore = nodeProto.insertBefore;
var nativeReplaceChild = nodeProto.replaceChild, nativeRemoveChild = nodeProto.removeChild;
function isFragment(n) { return n != null && n.nodeType === 11 }
function toNode(n) { return typeof n === 'object' && n !== null ? n : document.createTextNode(String(n)) }
function nodesOf(args) {
    if (args.length === 1) return toNode(args[0]);
    var f = document.createDocumentFragment();
    for (var i = 0; i < args.length; i++) nativeAppendChild.call(f, toNode(args[i]));
    return f;
}
// scripts put in the document by other scripts run (external ones fetched as a
// task, then their load or error event), as in browsers; type="module" ones do
// not (no modules here), so the nomodule fallbacks do
var ranScripts = new WeakSet(), dynamicScript = null;
function absolute(v) { try { return new URL(v, location.href).href } catch (e) { return v } }
function inserted(node) {
    if (node.nodeType !== 1 || node.tagName !== 'SCRIPT' || ranScripts.has(node) || !node.isConnected) return;
    var type = (node.getAttribute('type') || '').trim().toLowerCase();
    if (type && !/^(text|application)\/(x-)?(java|ecma)script$/.test(type)) return;
    ranScripts.add(node);
    var src = node.getAttribute('src');
    if (src === null) { executeScript(node, node.textContent); return }
    var url = absolute(src);
    setTimeout(function () {
        var text = null;
        try {
            var x = new XMLHttpRequest();
            x.open('GET', url, false);
            x.send();
            if (x.status >= 200 && x.status < 400) text = x.responseText;
        } catch (e) { }
        if (text === null) { node.dispatchEvent(new Event('error')); return }
        executeScript(node, text);
        node.dispatchEvent(new Event('load'));
    }, 0);
}
function executeScript(node, text) {
    var outer = dynamicScript;
    dynamicScript = node;
    try { (0, eval)(text) } catch (e) { reportError(e) } finally { dynamicScript = outer }
}
defAll(nodeProto, {
    appendChild: function appendChild(child) {
        if (isFragment(child)) { var c; while ((c = child.firstChild)) { nativeAppendChild.call(this, c); inserted(c) } return child }
        var r = nativeAppendChild.call(this, child);
        inserted(child);
        return r;
    },
    insertBefore: function insertBefore(child, ref) {
        if (ref === undefined) ref = null;
        if (isFragment(child)) { var c; while ((c = child.firstChild)) { nativeInsertBefore.call(this, c, ref); inserted(c) } return child }
        var r = nativeInsertBefore.call(this, child, ref);
        inserted(child);
        return r;
    },
    replaceChild: function replaceChild(child, old) {
        if (isFragment(child)) { this.insertBefore(child, old); nativeRemoveChild.call(this, old); return old }
        var r = nativeReplaceChild.call(this, child, old);
        inserted(child);
        return r;
    },
    append: function append() { this.appendChild(nodesOf(arguments)) },
    prepend: function prepend() { this.insertBefore(nodesOf(arguments), this.firstChild) },
    before: function before() { if (this.parentNode) this.parentNode.insertBefore(nodesOf(arguments), this) },
    after: function after() { if (this.parentNode) this.parentNode.insertBefore(nodesOf(arguments), this.nextSibling) },
    replaceWith: function replaceWith() {
        var p = this.parentNode;
        if (p) { var n = nodesOf(arguments); p.insertBefore(n, this); if (this.parentNode === p) nativeRemoveChild.call(p, this) }
    },
    replaceChildren: function replaceChildren() {
        var c; while ((c = this.firstChild)) nativeRemoveChild.call(this, c);
        if (arguments.length) this.appendChild(nodesOf(arguments));
    },
    getRootNode: function getRootNode() { var n = this; while (n.parentNode) n = n.parentNode; return n },
    isSameNode: function isSameNode(o) { return this === o },
    isEqualNode: function isEqualNode(o) {
        return o != null && this.nodeType === o.nodeType && (this.nodeType === 1 ? this.outerHTML === o.outerHTML : this.textContent === o.textContent);
    },
    compareDocumentPosition: function compareDocumentPosition(o) {
        if (this === o) return 0;
        if (this.contains(o)) return 20;       // contained by + following
        if (o.contains(this)) return 10;       // contains + preceding
        if (this.getRootNode() !== o.getRootNode()) return 1 | 32;
        // document order: walk from the root
        var all = [], root = this.getRootNode();
        (function walk(n) { all.push(n); for (var c = n.firstChild; c; c = c.nextSibling) walk(c) })(root);
        return all.indexOf(o) > all.indexOf(this) ? 4 : 2;
    },
    normalize: function normalize() { },
    lookupNamespaceURI: function lookupNamespaceURI() { return 'http://www.w3.org/1999/xhtml' },
    lookupPrefix: function lookupPrefix() { return null },
    isDefaultNamespace: function isDefaultNamespace(ns) { return ns === 'http://www.w3.org/1999/xhtml' },
});
getter(nodeProto, 'baseURI', function () { return location.href });
getter(nodeProto, 'namespaceURI', function () { return this.nodeType === 1 ? (this instanceof SVGElement ? 'http://www.w3.org/2000/svg' : 'http://www.w3.org/1999/xhtml') : null });

// --- selectors the native engine does not know ------------------------------------------
// The native querySelector(All) / matches / closest handle type, #id, .class,
// descendant and child combinators; for the rest (attributes, + and ~, most
// pseudo-classes) they throw a SyntaxError and these take over.
function splitTop(s, sep) {
    // split at `sep` characters outside (), [] and quotes
    var out = [], depth = 0, quote = '', start = 0;
    for (var i = 0; i < s.length; i++) {
        var c = s[i];
        if (quote) { if (c === '\\') i++; else if (c === quote) quote = ''; continue }
        if (c === '"' || c === "'") quote = c;
        else if (c === '(' || c === '[') depth++;
        else if (c === ')' || c === ']') depth--;
        else if (c === '\\') i++;
        else if (depth === 0 && sep.indexOf(c) >= 0) { out.push(s.slice(start, i)); start = i + 1 }
    }
    out.push(s.slice(start));
    return out;
}
var selectorCache = new Map();
function badSelector(s) { return new SyntaxError("'" + s + "' is not a valid selector") }
// a selector list -> [[{comb, compound}...]...], compounds right to left
function parseSelectorList(text) {
    var cached = selectorCache.get(text);
    if (cached) return cached;
    var list = splitTop(text, ',').map(function (s) { return parseComplex(s.trim(), text) });
    if (selectorCache.size > 200) selectorCache.clear();
    selectorCache.set(text, list);
    return list;
}
function parseComplex(s, whole) {
    if (!s) throw badSelector(whole);
    var parts = [], i = 0, comb = null;
    while (i < s.length) {
        var c = s[i];
        if (c === ' ' || c === '\t' || c === '\n' || c === '>' || c === '+' || c === '~') {
            var k = ' ';
            while (i < s.length && /[\s>+~]/.test(s[i])) { if (s[i] !== ' ' && s[i] !== '\t' && s[i] !== '\n') k = s[i]; i++ }
            if (!parts.length) { if (k === ' ') continue; throw badSelector(whole) }
            comb = k;
            continue;
        }
        var r = parseCompound(s, i, whole);
        parts.push({ comb: comb, compound: r.compound });
        comb = null;
        i = r.end;
    }
    if (comb || !parts.length) throw badSelector(whole);
    return parts.reverse();
}
function readName(s, i) {
    var start = i;
    while (i < s.length && (/[\w\-\u0080-￿]/.test(s[i]) || s[i] === '\\')) i += s[i] === '\\' ? 2 : 1;
    return { name: s.slice(start, i).replace(/\\(.)/g, '$1'), end: i };
}
function readParens(s, i, whole) {
    // s[i] is '(' -> the text inside, and past the ')'
    var depth = 0, quote = '', start = i + 1;
    for (; i < s.length; i++) {
        var c = s[i];
        if (quote) { if (c === '\\') i++; else if (c === quote) quote = ''; continue }
        if (c === '"' || c === "'") quote = c;
        else if (c === '(') depth++;
        else if (c === ')' && --depth === 0) return { text: s.slice(start, i), end: i + 1 };
    }
    throw badSelector(whole);
}
function parseCompound(s, i, whole) {
    var comp = { tag: null, tests: [] };
    if (s[i] === '*') i++;
    else if (/[\w\-]/.test(s[i])) { var n = readName(s, i); comp.tag = n.name.toUpperCase(); i = n.end }
    while (i < s.length && !/[\s>+~]/.test(s[i])) {
        var c = s[i], r;
        if (c === '#') { r = readName(s, i + 1); comp.tests.push({ t: 'id', v: r.name }); i = r.end }
        else if (c === '.') { r = readName(s, i + 1); comp.tests.push({ t: 'class', v: r.name }); i = r.end }
        else if (c === '[') {
            var close = i + 1, quote = '';
            for (; close < s.length; close++) {
                if (quote) { if (s[close] === '\\') close++; else if (s[close] === quote) quote = '' }
                else if (s[close] === '"' || s[close] === "'") quote = s[close];
                else if (s[close] === ']') break;
            }
            var m = /^\s*([^\s~|^$*!=]+)\s*(?:([~|^$*!]?=)\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s\]]*)\s*(i|s)?)?\s*$/i.exec(s.slice(i + 1, close));
            if (!m) throw badSelector(whole);
            var v = m[3];
            if (v && (v[0] === '"' || v[0] === "'")) v = v.slice(1, -1).replace(/\\(.)/g, '$1');
            comp.tests.push({ t: 'attr', name: m[1].toLowerCase(), op: m[2] || '', v: v === undefined ? '' : v, ci: m[4] && m[4].toLowerCase() === 'i' });
            i = close + 1;
        } else if (c === ':') {
            var element = s[i + 1] === ':';
            r = readName(s, i + (element ? 2 : 1));
            var name = r.name.toLowerCase(), arg = null;
            i = r.end;
            if (s[i] === '(') { var p = readParens(s, i, whole); arg = p.text.trim(); i = p.end }
            if (element || /^(before|after|first-line|first-letter|placeholder|selection|marker|backdrop)$/.test(name)) comp.tests.push({ t: 'never' });
            else comp.tests.push(pseudo(name, arg, whole));
        } else throw badSelector(whole);
    }
    return { compound: comp, end: i };
}
function nthTest(arg, whole) {
    // an+b [of S]
    arg = arg.toLowerCase();
    var of = null, ofAt = arg.indexOf(' of ');
    if (ofAt >= 0) { of = parseSelectorList(arg.slice(ofAt + 4)); arg = arg.slice(0, ofAt).trim() }
    if (arg === 'odd') return { a: 2, b: 1, of: of };
    if (arg === 'even') return { a: 2, b: 0, of: of };
    var m = /^([+-]?\d*)n\s*(?:([+-])\s*(\d+))?$/.exec(arg);
    if (m) return { a: m[1] === '' || m[1] === '+' ? 1 : m[1] === '-' ? -1 : Number(m[1]), b: m[2] ? Number(m[2] + m[3]) : 0, of: of };
    if (/^[+-]?\d+$/.test(arg)) return { a: 0, b: Number(arg), of: of };
    throw badSelector(whole);
}
function pseudo(name, arg, whole) {
    switch (name) {
    case 'not': case 'is': case 'where': case 'matches': case 'any': case '-webkit-any':
        return { t: name === 'not' ? 'not' : 'is', list: parseSelectorList(arg) };
    case 'has':
        return { t: 'has', list: parseSelectorList(arg.replace(/^\s*[>+~]/, function (c) { return ':scope ' + c.trim() })) };
    case 'nth-child': case 'nth-last-child': case 'nth-of-type': case 'nth-last-of-type':
        return { t: name, n: nthTest(arg, whole) };
    case 'lang': return { t: 'lang', v: arg.toLowerCase() };
    case 'first-child': case 'last-child': case 'only-child': case 'first-of-type': case 'last-of-type': case 'only-of-type':
    case 'empty': case 'root': case 'checked': case 'disabled': case 'enabled': case 'selected': case 'required': case 'optional':
    case 'read-only': case 'read-write': case 'link': case 'any-link': case 'focus': case 'focus-within': case 'focus-visible':
    case 'scope': case 'placeholder-shown': case 'defined': case 'indeterminate': case 'default': case 'valid': case 'invalid':
    case 'hover': case 'active': case 'visited': case 'target': case 'fullscreen': case 'modal': case 'open':
        return { t: name };
    }
    throw badSelector(whole);
}
function position(el, sameType, fromEnd, of, scope) {
    var n = 0;
    for (var s = fromEnd ? el.nextSibling : el.previousSibling; s; s = fromEnd ? s.nextSibling : s.previousSibling) {
        if (s.nodeType !== 1) continue;
        if (sameType && s.tagName !== el.tagName) continue;
        if (of && !matchesList(s, of, scope)) continue;
        n++;
    }
    return n + 1;
}
function nthMatches(n, pos) {
    if (n.a === 0) return pos === n.b;
    var k = (pos - n.b) / n.a;
    return k >= 0 && Math.floor(k) === k;
}
function attrMatches(el, t) {
    var v = el.getAttribute(t.name);
    if (v === null) return false;
    if (!t.op) return true;
    var want = t.v;
    if (t.ci) { v = v.toLowerCase(); want = want.toLowerCase() }
    switch (t.op) {
    case '=': return v === want;
    case '~=': return want !== '' && v.split(/\s+/).indexOf(want) >= 0;
    case '|=': return v === want || v.slice(0, want.length + 1) === want + '-';
    case '^=': return want !== '' && v.slice(0, want.length) === want;
    case '$=': return want !== '' && v.slice(-want.length) === want;
    case '*=': return want !== '' && v.indexOf(want) >= 0;
    case '!=': return v !== want;
    }
    return false;
}
function testMatches(el, t, scope) {
    switch (t.t) {
    case 'id': return el.id === t.v;
    case 'class': return (' ' + el.className + ' ').replace(/\s+/g, ' ').indexOf(' ' + t.v + ' ') >= 0;
    case 'attr': return attrMatches(el, t);
    case 'never': return false;
    case 'not': return !matchesList(el, t.list, scope);
    case 'is': return matchesList(el, t.list, scope);
    case 'has': return !!queryAll(el, t.list, true, el).length;
    case 'first-child': return position(el, false, false) === 1;
    case 'last-child': return position(el, false, true) === 1;
    case 'only-child': return position(el, false, false) === 1 && position(el, false, true) === 1;
    case 'first-of-type': return position(el, true, false) === 1;
    case 'last-of-type': return position(el, true, true) === 1;
    case 'only-of-type': return position(el, true, false) === 1 && position(el, true, true) === 1;
    case 'nth-child': return nthMatches(t.n, position(el, false, false, t.n.of, scope));
    case 'nth-last-child': return nthMatches(t.n, position(el, false, true, t.n.of, scope));
    case 'nth-of-type': return nthMatches(t.n, position(el, true, false));
    case 'nth-last-of-type': return nthMatches(t.n, position(el, true, true));
    case 'empty': for (var c = el.firstChild; c; c = c.nextSibling) if (c.nodeType === 1 || c.nodeType === 3 && c.data) return false; return true;
    case 'root': return el === document.documentElement;
    case 'scope': return scope ? el === scope : el === document.documentElement;
    case 'checked': return el.tagName === 'OPTION' ? el.selected : !!el.checked;
    case 'disabled': return !!el.disabled;
    case 'enabled': return /^(INPUT|BUTTON|SELECT|TEXTAREA|OPTION|FIELDSET)$/.test(el.tagName) && !el.disabled;
    case 'selected': return el.hasAttribute('selected');
    case 'required': return el.hasAttribute('required');
    case 'optional': return /^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName) && !el.hasAttribute('required');
    case 'read-only': return !/^(INPUT|TEXTAREA)$/.test(el.tagName) || el.hasAttribute('readonly');
    case 'read-write': return /^(INPUT|TEXTAREA)$/.test(el.tagName) && !el.hasAttribute('readonly');
    case 'link': case 'any-link': return /^(A|AREA)$/.test(el.tagName) && el.hasAttribute('href');
    case 'focus': case 'focus-visible': return document.activeElement === el;
    case 'focus-within': return el.contains(document.activeElement);
    case 'placeholder-shown': return el.hasAttribute('placeholder') && !el.value;
    case 'defined': return true;
    case 'default': return el.hasAttribute('checked') || el.hasAttribute('selected');
    case 'valid': return true;
    case 'invalid': return false;
    case 'open': return el.hasAttribute('open');
    case 'lang': for (var n = el; n && n.nodeType === 1; n = n.parentNode) { var l = n.getAttribute('lang'); if (l !== null) return l.toLowerCase() === t.v || l.toLowerCase().indexOf(t.v + '-') === 0 } return false;
    }
    return false;    // hover, active, visited, target, ...
}
function compoundMatches(el, comp, scope) {
    if (el.nodeType !== 1) return false;
    if (comp.tag && el.tagName !== comp.tag) return false;
    for (var t of comp.tests) if (!testMatches(el, t, scope)) return false;
    return true;
}
// parts are right to left: parts[i].comb joins parts[i] to parts[i + 1], the
// compound on its left (' ', '>', '+' or '~')
function complexMatches(el, parts, i, scope) {
    if (!compoundMatches(el, parts[i].compound, scope)) return false;
    if (i === parts.length - 1) return true;
    switch (parts[i].comb) {
    case '>': { var p = el.parentNode; return !!p && p.nodeType === 1 && complexMatches(p, parts, i + 1, scope) }
    case '+': { var s = el.previousElementSibling; return !!s && complexMatches(s, parts, i + 1, scope) }
    case '~': for (var s2 = el.previousElementSibling; s2; s2 = s2.previousElementSibling) if (complexMatches(s2, parts, i + 1, scope)) return true; return false;
    default: for (var a = el.parentNode; a && a.nodeType === 1; a = a.parentNode) if (complexMatches(a, parts, i + 1, scope)) return true; return false;
    }
}
function matchesList(el, list, scope) {
    for (var parts of list) if (complexMatches(el, parts, 0, scope)) return true;
    return false;
}
function queryAll(root, list, firstOnly, scope) {
    var out = [];
    (function walk(n) {
        for (var c = n.firstChild; c; c = c.nextSibling) {
            if (c.nodeType !== 1) continue;
            if (matchesList(c, list, scope)) { out.push(c); if (firstOnly) return true }
            if (walk(c)) return true;
        }
    })(root);
    return out;
}
var nativeQS = nodeProto.querySelector, nativeQSA = nodeProto.querySelectorAll;
var nativeMatches = nodeProto.matches, nativeClosest = nodeProto.closest;
function scopeOf(node) { return node.nodeType === 9 ? node.documentElement : node }
defAll(nodeProto, {
    querySelector: function querySelector(s) {
        try { return nativeQS.call(this, s) } catch (e) {
            if (!(e instanceof SyntaxError)) throw e;
            return queryAll(this, parseSelectorList(String(s)), true, scopeOf(this))[0] || null;
        }
    },
    querySelectorAll: function querySelectorAll(s) {
        try { return nativeQSA.call(this, s) } catch (e) {
            if (!(e instanceof SyntaxError)) throw e;
            return queryAll(this, parseSelectorList(String(s)), false, scopeOf(this));
        }
    },
    matches: function matches(s) {
        try { return nativeMatches.call(this, s) } catch (e) {
            if (!(e instanceof SyntaxError)) throw e;
            return matchesList(this, parseSelectorList(String(s)), this);
        }
    },
    closest: function closest(s) {
        try { return nativeClosest.call(this, s) } catch (e) {
            if (!(e instanceof SyntaxError)) throw e;
            var list = parseSelectorList(String(s));
            for (var n = this; n && n.nodeType === 1; n = n.parentNode) if (matchesList(n, list, this)) return n;
            return null;
        }
    },
});

// --- elements ----------------------------------------------------------------------------
function camel(s) { return s.replace(/-([a-z])/g, function (m, c) { return c.toUpperCase() }) }
function kebab(s) { return s.replace(/[A-Z]/g, function (c) { return '-' + c.toLowerCase() }) }
var ep = Element.prototype;
function rect(x, y, w, h) {
    return { x: x, y: y, left: x, top: y, width: w, height: h, right: x + w, bottom: y + h, toJSON: function () { return this } };
}
function shown(el) {
    for (var n = el; n && n.nodeType === 1; n = n.parentNode)
        if (n.hidden || n.style && n.style.display === 'none') return false;
    return el.isConnected;
}
defAll(ep, {
    insertAdjacentHTML: function insertAdjacentHTML(where, html) {
        var t = document.createElement('div');
        t.innerHTML = html;
        var f = document.createDocumentFragment();
        var c; while ((c = t.firstChild)) nativeAppendChild.call(f, c);
        this.insertAdjacentElement(where, f);
    },
    insertAdjacentElement: function insertAdjacentElement(where, node) {
        switch (String(where).toLowerCase()) {
        case 'beforebegin': if (this.parentNode) this.parentNode.insertBefore(node, this); break;
        case 'afterbegin': this.insertBefore(node, this.firstChild); break;
        case 'beforeend': this.appendChild(node); break;
        case 'afterend': if (this.parentNode) this.parentNode.insertBefore(node, this.nextSibling); break;
        default: throw new SyntaxError("Failed to execute 'insertAdjacentElement': '" + where + "' is not a valid position");
        }
        return node;
    },
    insertAdjacentText: function insertAdjacentText(where, text) { this.insertAdjacentElement(where, document.createTextNode(text)) },
    toggleAttribute: function toggleAttribute(name, force) {
        var on = force === undefined ? !this.hasAttribute(name) : !!force;
        if (on) { if (!this.hasAttribute(name)) this.setAttribute(name, '') } else this.removeAttribute(name);
        return on;
    },
    hasAttributes: function hasAttributes() { return this.getAttributeNames().length > 0 },
    getAttributeNS: function getAttributeNS(ns, name) { return this.getAttribute(name) },
    setAttributeNS: function setAttributeNS(ns, name, value) { this.setAttribute(name.replace(/^.*:/, ''), value) },
    removeAttributeNS: function removeAttributeNS(ns, name) { this.removeAttribute(name) },
    hasAttributeNS: function hasAttributeNS(ns, name) { return this.hasAttribute(name) },
    getAttributeNode: function getAttributeNode(name) {
        return this.hasAttribute(name) ? { name: name, value: this.getAttribute(name), specified: true, ownerElement: this } : null;
    },
    webkitMatchesSelector: function webkitMatchesSelector(s) { return this.matches(s) },
    msMatchesSelector: function msMatchesSelector(s) { return this.matches(s) },
    getBoundingClientRect: function getBoundingClientRect() {
        return shown(this) ? rect(0, 0, this.offsetWidth, this.offsetHeight) : rect(0, 0, 0, 0);
    },
    getClientRects: function getClientRects() { return shown(this) ? [this.getBoundingClientRect()] : [] },
    scrollIntoView: function scrollIntoView() { },
    scrollIntoViewIfNeeded: function scrollIntoViewIfNeeded() { },
    scroll: function scroll() { }, scrollTo: function scrollTo() { }, scrollBy: function scrollBy() { },
    animate: function animate() {
        var a = { playState: 'finished', onfinish: null, oncancel: null, currentTime: 0,
            cancel: function () { }, finish: function () { }, play: function () { }, pause: function () { }, reverse: function () { },
            addEventListener: function () { }, removeEventListener: function () { } };
        a.finished = Promise.resolve(a);
        return a;
    },
    getAnimations: function getAnimations() { return [] },
    attachShadow: function attachShadow(init) {
        // (drawn in place of the element's children: they share its content)
        def(this, 'shadowRoot', init && init.mode === 'closed' ? null : this);
        return this;
    },
    requestFullscreen: function requestFullscreen() { return Promise.reject(new Error('Fullscreen is not supported')) },
    setPointerCapture: function setPointerCapture() { }, releasePointerCapture: function releasePointerCapture() { },
    hasPointerCapture: function hasPointerCapture() { return false },
});
getter(ep, 'localName', function () { return this.tagName.toLowerCase() });
getter(ep, 'src', function () { var v = this.getAttribute('src'); return v === null ? '' : absolute(v) }, function (v) { this.setAttribute('src', v) });
getter(ep, 'href', function () {
    var v = this.getAttribute('href');
    if (v === null) return '';
    return /^(A|AREA|LINK|BASE)$/.test(this.tagName) ? absolute(v) : v;
}, function (v) { this.setAttribute('href', v) });
getter(ep, 'prefix', function () { return null });
getter(ep, 'attributes', function () {
    var el = this, list = this.getAttributeNames().map(function (n) {
        return { name: n, localName: n, value: el.getAttribute(n), specified: true, ownerElement: el, nodeType: 2, nodeName: n };
    });
    list.item = function (i) { return this[i] || null };
    list.getNamedItem = function (n) { n = String(n).toLowerCase(); return this.find(function (a) { return a.name === n }) || null };
    return list;
});
getter(ep, 'dataset', function () {
    var el = this, map = {};
    for (var n of this.getAttributeNames()) {
        if (n.slice(0, 5) !== 'data-') continue;
        (function (attr) {
            Object.defineProperty(map, camel(attr.slice(5)), {
                get: function () { return el.getAttribute(attr) },
                set: function (v) { el.setAttribute(attr, v) },
                enumerable: true, configurable: true,
            });
        })(n);
    }
    return map;
});
// sizes: the layout is not visible to scripts; shown elements get a nominal box
function width(el) { return shown(el) ? (el.tagName === 'BODY' || el.tagName === 'HTML' ? innerWidth : Math.min(innerWidth, 600)) : 0 }
function height(el) { return shown(el) ? (el.tagName === 'BODY' || el.tagName === 'HTML' ? innerHeight : 20) : 0 }
getter(ep, 'offsetWidth', function () { return width(this) });
getter(ep, 'offsetHeight', function () { return height(this) });
getter(ep, 'clientWidth', function () { return width(this) });
getter(ep, 'clientHeight', function () { return height(this) });
getter(ep, 'scrollWidth', function () { return width(this) });
getter(ep, 'scrollHeight', function () { return height(this) });
getter(ep, 'offsetTop', function () { return 0 });
getter(ep, 'offsetLeft', function () { return 0 });
getter(ep, 'clientTop', function () { return 0 });
getter(ep, 'clientLeft', function () { return 0 });
getter(ep, 'offsetParent', function () { return shown(this) ? this.parentElement : null });
var scrollPos = new WeakMap();
getter(ep, 'scrollTop', function () { return (scrollPos.get(this) || [0, 0])[1] }, function (v) { scrollPos.set(this, [this.scrollLeft, Number(v) || 0]) });
getter(ep, 'scrollLeft', function () { return (scrollPos.get(this) || [0, 0])[0] }, function (v) { scrollPos.set(this, [Number(v) || 0, this.scrollTop]) });
getter(ep, 'slot', function () { return this.getAttribute('slot') || '' }, function (v) { this.setAttribute('slot', v) });
getter(ep, 'assignedSlot', function () { return null });
if (!('shadowRoot' in ep)) def(ep, 'shadowRoot', null);
var hp = HTMLElement.prototype;
getter(hp, 'dir', function () { return this.getAttribute('dir') || '' }, function (v) { this.setAttribute('dir', v) });
getter(hp, 'lang', function () { return this.getAttribute('lang') || '' }, function (v) { this.setAttribute('lang', v) });
getter(hp, 'tabIndex', function () { var t = this.getAttribute('tabindex'); return t === null ? -1 : Number(t) }, function (v) { this.setAttribute('tabindex', v) });
getter(hp, 'draggable', function () { return this.getAttribute('draggable') === 'true' }, function (v) { this.setAttribute('draggable', String(!!v)) });
getter(hp, 'contentEditable', function () { return this.getAttribute('contenteditable') || 'inherit' }, function (v) { this.setAttribute('contenteditable', v) });
getter(hp, 'isContentEditable', function () { return this.getAttribute('contenteditable') === 'true' });
getter(hp, 'accessKey', function () { return this.getAttribute('accesskey') || '' });
getter(hp, 'inert', function () { return this.hasAttribute('inert') }, function (v) { this.toggleAttribute('inert', !!v) });
defAll(hp, { showPopover: function () { }, hidePopover: function () { }, togglePopover: function () { } });
// form controls
var formProtos = [HTMLInputElement, HTMLSelectElement, HTMLTextAreaElement, HTMLButtonElement].map(function (C) { return C.prototype });
for (var fp of formProtos) {
    getter(fp, 'form', function () { return this.closest('form') });
    getter(fp, 'required', function () { return this.hasAttribute('required') }, function (v) { this.toggleAttribute('required', !!v) });
    getter(fp, 'readOnly', function () { return this.hasAttribute('readonly') }, function (v) { this.toggleAttribute('readonly', !!v) });
    getter(fp, 'validity', function () { return { valid: true, valueMissing: false, typeMismatch: false, patternMismatch: false, tooLong: false, tooShort: false, customError: false } });
    getter(fp, 'validationMessage', function () { return '' });
    getter(fp, 'willValidate', function () { return true });
    defAll(fp, {
        checkValidity: function () { return true }, reportValidity: function () { return true }, setCustomValidity: function () { },
        select: function () { }, setSelectionRange: function () { },
    });
}
getter(HTMLInputElement.prototype, 'defaultValue', function () { return this.getAttribute('value') || '' }, function (v) { this.setAttribute('value', v) });
getter(HTMLInputElement.prototype, 'defaultChecked', function () { return this.hasAttribute('checked') });
getter(HTMLInputElement.prototype, 'files', function () { return [] });
getter(HTMLSelectElement.prototype, 'options', function () { return this.querySelectorAll('option') });
getter(HTMLSelectElement.prototype, 'selectedIndex', function () {
    var o = this.querySelectorAll('option');
    for (var i = 0; i < o.length; i++) if (o[i].hasAttribute('selected')) return i;
    return o.length ? 0 : -1;
}, function (v) {
    var o = this.querySelectorAll('option');
    for (var i = 0; i < o.length; i++) o[i].toggleAttribute('selected', i === Number(v));
});
getter(HTMLOptionElement.prototype, 'selected', function () { return this.hasAttribute('selected') }, function (v) { this.toggleAttribute('selected', !!v) });
getter(HTMLOptionElement.prototype, 'text', function () { return this.textContent }, function (v) { this.textContent = v });
getter(HTMLFormElement.prototype, 'elements', function () { return this.querySelectorAll('input, select, textarea, button') });
getter(HTMLFormElement.prototype, 'action', function () { return this.getAttribute('action') || location.href });
getter(HTMLFormElement.prototype, 'method', function () { return (this.getAttribute('method') || 'get').toLowerCase() });
defAll(HTMLFormElement.prototype, {
    submit: function submit() { formSubmit(this) }, reset: function reset() { },
    requestSubmit: function requestSubmit(button) {
        if (this.dispatchEvent(new SubmitEvent('submit', { bubbles: true, cancelable: true, submitter: button || null }))) formSubmit(this, button);
    },
    checkValidity: function checkValidity() { return true }, reportValidity: function reportValidity() { return true },
});
getter(HTMLAnchorElement.prototype, 'pathname', function () { return new URL(this.href || '', location.href).pathname });
getter(HTMLAnchorElement.prototype, 'hostname', function () { return new URL(this.href || '', location.href).hostname });
getter(HTMLAnchorElement.prototype, 'protocol', function () { return new URL(this.href || '', location.href).protocol });
getter(HTMLAnchorElement.prototype, 'search', function () { return new URL(this.href || '', location.href).search });
getter(HTMLAnchorElement.prototype, 'hash', function () { return new URL(this.href || '', location.href).hash });
getter(HTMLAnchorElement.prototype, 'host', function () { return new URL(this.href || '', location.href).host });
getter(HTMLAnchorElement.prototype, 'origin', function () { return new URL(this.href || '', location.href).origin });
getter(HTMLImageElement.prototype, 'complete', function () { return true });
getter(HTMLImageElement.prototype, 'naturalWidth', function () { return Number(this.getAttribute('width')) || 0 });
getter(HTMLImageElement.prototype, 'naturalHeight', function () { return Number(this.getAttribute('height')) || 0 });
getter(HTMLImageElement.prototype, 'width', function () { return Number(this.getAttribute('width')) || 0 }, function (v) { this.setAttribute('width', v) });
getter(HTMLImageElement.prototype, 'height', function () { return Number(this.getAttribute('height')) || 0 }, function (v) { this.setAttribute('height', v) });
getter(HTMLImageElement.prototype, 'srcset', function () { return this.getAttribute('srcset') || '' }, function (v) { this.setAttribute('srcset', v) });
getter(HTMLImageElement.prototype, 'loading', function () { return this.getAttribute('loading') || 'eager' }, function (v) { this.setAttribute('loading', v) });
def(HTMLImageElement.prototype, 'decode', function decode() { return Promise.resolve() });
getter(HTMLTemplateElement.prototype, 'content', function () {
    var f = document.createDocumentFragment();
    for (var c = this.firstChild; c; c = c.nextSibling) nativeAppendChild.call(f, c.cloneNode(true));
    return f;
});
getter(HTMLScriptElement.prototype, 'async', function () { return this.hasAttribute('async') }, function (v) { this.toggleAttribute('async', !!v) });
getter(HTMLScriptElement.prototype, 'defer', function () { return this.hasAttribute('defer') }, function (v) { this.toggleAttribute('defer', !!v) });
getter(HTMLScriptElement.prototype, 'text', function () { return this.textContent }, function (v) { this.textContent = v });
getter(HTMLIFrameElement.prototype, 'contentWindow', function () { return null });
getter(HTMLIFrameElement.prototype, 'contentDocument', function () { return null });
defAll(HTMLMediaElement.prototype, {
    play: function play() { return Promise.resolve() }, pause: function pause() { }, load: function load() { },
    canPlayType: function canPlayType() { return '' },
});
getter(HTMLMediaElement.prototype, 'paused', function () { return true });
getter(HTMLMediaElement.prototype, 'muted', function () { return this.hasAttribute('muted') }, function (v) { this.toggleAttribute('muted', !!v) });
defAll(HTMLDialogElement.prototype, {
    show: function show() { this.setAttribute('open', '') }, showModal: function showModal() { this.setAttribute('open', '') },
    close: function close(v) { this.removeAttribute('open'); this.returnValue = v === undefined ? '' : String(v); this.dispatchEvent(new Event('close')) },
});
getter(HTMLDialogElement.prototype, 'open', function () { return this.hasAttribute('open') }, function (v) { this.toggleAttribute('open', !!v) });
getter(HTMLDetailsElement.prototype, 'open', function () { return this.hasAttribute('open') }, function (v) { this.toggleAttribute('open', !!v) });
def(HTMLCanvasElement.prototype, 'getContext', function getContext() { return null });
def(HTMLCanvasElement.prototype, 'toDataURL', function toDataURL() { return 'data:,' });

// text and comments
var cp = CharacterData.prototype;
getter(cp, 'length', function () { return this.data.length });
defAll(cp, {
    appendData: function appendData(s) { this.data += s },
    deleteData: function deleteData(o, n) { this.data = this.data.slice(0, o) + this.data.slice(o + n) },
    insertData: function insertData(o, s) { this.data = this.data.slice(0, o) + s + this.data.slice(o) },
    replaceData: function replaceData(o, n, s) { this.data = this.data.slice(0, o) + s + this.data.slice(o + n) },
    substringData: function substringData(o, n) { return this.data.substr(o, n) },
});
getter(Text.prototype, 'wholeText', function () { return this.data });
def(Text.prototype, 'splitText', function splitText(o) {
    var rest = document.createTextNode(this.data.slice(o));
    this.data = this.data.slice(0, o);
    if (this.parentNode) this.parentNode.insertBefore(rest, this.nextSibling);
    return rest;
});

// --- document ------------------------------------------------------------------------------
// a detached document: DOMParser, createHTMLDocument (its nodes are this page's)
function detachedDocument(html) {
    var root = document.createElement('html');
    var head = document.createElement('head'), body = document.createElement('body');
    nativeAppendChild.call(root, head);
    nativeAppendChild.call(root, body);
    if (html) {
        var t = document.createElement('div');
        t.innerHTML = String(html).replace(/<!doctype[^>]*>/i, '');
        var src = t.querySelector('body') || t;
        var hd = t.querySelector('head');
        if (hd) { var c; while ((c = hd.firstChild)) nativeAppendChild.call(head, c) }
        while ((c = src.firstChild)) {
            if (c.nodeType === 1 && (c.tagName === 'HEAD' || c.tagName === 'HTML')) { nativeRemoveChild.call(src, c); continue }
            nativeAppendChild.call(body, c);
        }
    }
    var d = Object.create(HTMLDocument.prototype);
    var own = {
        nodeType: 9, nodeName: '#document', documentElement: root, head: head, body: body, defaultView: null,
        title: '', readyState: 'complete', location: null, implementation: document.implementation,
        firstChild: root, lastChild: root, childNodes: [root], children: [root],
        createElement: function (n) { return document.createElement(n) },
        createElementNS: function (ns, n) { return document.createElement(n) },
        createTextNode: function (t) { return document.createTextNode(t) },
        createComment: function (t) { return document.createComment(t) },
        createDocumentFragment: function () { return document.createDocumentFragment() },
        getElementById: function (id) { return root.querySelector('#' + CSS.escape(id)) },
        querySelector: function (s) { return root.querySelector(s) },
        querySelectorAll: function (s) { return root.querySelectorAll(s) },
        getElementsByTagName: function (t) { return root.getElementsByTagName(t) },
        getElementsByClassName: function (c) { return root.getElementsByClassName(c) },
        importNode: function (n, deep) { return n.cloneNode(deep) },
        adoptNode: function (n) { return n },
        addEventListener: function () { }, removeEventListener: function () { },
    };
    for (var k of Object.keys(own)) def(d, k, own[k]);
    return d;
}
var implementation = {
    createHTMLDocument: function createHTMLDocument(title) { var d = detachedDocument(); d.title = title || ''; return d },
    createDocument: function createDocument() { return detachedDocument() },
    createDocumentType: function createDocumentType(name) { return { name: name, nodeType: 10 } },
    hasFeature: function hasFeature() { return true },
};
var focused = null;
defAll(nodeProto, {
    createElementNS: function createElementNS(ns, name) { return this.createElement(String(name).replace(/^.*:/, '')) },
    createEvent: function createEvent(type) {
        var C = global[String(type).replace(/s$/, '')] || Event;
        return new C('');
    },
    createRange: function createRange() { return new Range() },
    createTreeWalker: function createTreeWalker(root, what, filter) { return new TreeWalker(root, what, filter) },
    createNodeIterator: function createNodeIterator(root, what, filter) { return new TreeWalker(root, what, filter) },
    createAttribute: function createAttribute(name) { return { name: name, value: '', nodeType: 2 } },
    getElementsByName: function getElementsByName(name) { return this.querySelectorAll('[name="' + String(name).replace(/"/g, '\\"') + '"]') },
    importNode: function importNode(n, deep) { return n.cloneNode(deep) },
    adoptNode: function adoptNode(n) { if (n.parentNode) n.parentNode.removeChild(n); return n },
    hasFocus: function hasFocus() { return true },
    execCommand: function execCommand() { return false },
    queryCommandSupported: function queryCommandSupported() { return false },
    elementFromPoint: function elementFromPoint() { return document.body },
    elementsFromPoint: function elementsFromPoint() { return [document.body] },
    getSelection: function getSelection() { return global.getSelection() },
    open: function open() { return document }, close: function close() { },
    exitFullscreen: function exitFullscreen() { return Promise.resolve() },
    startViewTransition: function startViewTransition(cb) {
        var done = Promise.resolve().then(cb);
        return { finished: done, ready: done, updateCallbackDone: done, skipTransition: function () { } };
    },
});
var focusNative = nodeProto.focus, blurNative = nodeProto.blur;
defAll(nodeProto, {
    focus: function focus() { focused = this; focusNative.call(this) },
    blur: function blur() { if (focused === this) focused = null; blurNative.call(this) },
});
var dp = HTMLDocument.prototype;
getter(dp, 'implementation', function () { return implementation });
getter(dp, 'defaultView', function () { return this === document ? global : null });
getter(dp, 'activeElement', function () { return focused && focused.isConnected ? focused : document.body });
getter(dp, 'visibilityState', function () { return 'visible' });
getter(dp, 'hidden', function () { return false });
getter(dp, 'characterSet', function () { return 'UTF-8' });
getter(dp, 'charset', function () { return 'UTF-8' });
getter(dp, 'inputEncoding', function () { return 'UTF-8' });
getter(dp, 'contentType', function () { return 'text/html' });
getter(dp, 'compatMode', function () { return 'CSS1Compat' });
getter(dp, 'doctype', function () { return { name: 'html', nodeType: 10, publicId: '', systemId: '' } });
getter(dp, 'referrer', function () { return '' });
getter(dp, 'domain', function () { return location.hostname });
getter(dp, 'lastModified', function () { return new Date().toLocaleString() });
getter(dp, 'dir', function () { return document.documentElement.getAttribute('dir') || '' });
getter(dp, 'scrollingElement', function () { return document.documentElement });
getter(dp, 'fullscreenElement', function () { return null });
getter(dp, 'fullscreenEnabled', function () { return false });
getter(dp, 'pointerLockElement', function () { return null });
getter(dp, 'forms', function () { return document.querySelectorAll('form') });
getter(dp, 'images', function () { return document.querySelectorAll('img') });
getter(dp, 'links', function () { return document.querySelectorAll('a[href], area[href]') });
getter(dp, 'scripts', function () { return document.querySelectorAll('script') });
getter(dp, 'styleSheets', function () { return [] });
getter(dp, 'fonts', function () { return fonts });
getter(dp, 'timeline', function () { return { currentTime: performance.now() } });
getter(dp, 'currentScript', function () { return dynamicScript || pageScript() });
var fonts = { ready: Promise.resolve(), status: 'loaded', size: 0,
    check: function () { return true }, load: function () { return Promise.resolve([]) },
    add: function () { }, delete: function () { }, forEach: function () { },
    addEventListener: function () { }, removeEventListener: function () { } };
fonts.ready = Promise.resolve(fonts);

// --- TreeWalker, Range, Selection ------------------------------------------------------------
var NodeFilter = { FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3, SHOW_ALL: 0xFFFFFFFF, SHOW_ELEMENT: 1,
    SHOW_ATTRIBUTE: 2, SHOW_TEXT: 4, SHOW_CDATA_SECTION: 8, SHOW_PROCESSING_INSTRUCTION: 64, SHOW_COMMENT: 128,
    SHOW_DOCUMENT: 256, SHOW_DOCUMENT_TYPE: 512, SHOW_DOCUMENT_FRAGMENT: 1024 };
def(global, 'NodeFilter', NodeFilter);
class TreeWalker {
    constructor(root, what, filter) {
        this.root = root;
        this.whatToShow = what === undefined ? NodeFilter.SHOW_ALL : what >>> 0;
        this.filter = filter || null;
        this.currentNode = root;
    }
    [' accept'](n) {
        if (!(this.whatToShow & (1 << (n.nodeType - 1)))) return NodeFilter.FILTER_SKIP;
        var f = this.filter;
        if (!f) return NodeFilter.FILTER_ACCEPT;
        return typeof f === 'function' ? f(n) : f.acceptNode(n);
    }
    [' following'](n, skipChildren) {
        if (!skipChildren && n.firstChild) return n.firstChild;
        while (n && n !== this.root) {
            if (n.nextSibling) return n.nextSibling;
            n = n.parentNode;
        }
        return null;
    }
    nextNode() {
        var n = this.currentNode, reject = false;
        while ((n = this[' following'](n, reject))) {
            var r = this[' accept'](n);
            reject = r === NodeFilter.FILTER_REJECT;
            if (r === NodeFilter.FILTER_ACCEPT) { this.currentNode = n; return n }
        }
        return null;
    }
    previousNode() {
        var n = this.currentNode;
        while (n !== this.root) {
            var p = n.previousSibling;
            if (p) { while (p.lastChild) p = p.lastChild; n = p } else n = n.parentNode;
            if (!n) return null;
            if (this[' accept'](n) === NodeFilter.FILTER_ACCEPT) { this.currentNode = n; return n }
        }
        return null;
    }
    parentNode() {
        var n = this.currentNode;
        while (n !== this.root && (n = n.parentNode)) if (this[' accept'](n) === NodeFilter.FILTER_ACCEPT) { this.currentNode = n; return n }
        return null;
    }
    firstChild() {
        for (var n = this.currentNode.firstChild; n; n = n.nextSibling) if (this[' accept'](n) === NodeFilter.FILTER_ACCEPT) { this.currentNode = n; return n }
        return null;
    }
    lastChild() {
        for (var n = this.currentNode.lastChild; n; n = n.previousSibling) if (this[' accept'](n) === NodeFilter.FILTER_ACCEPT) { this.currentNode = n; return n }
        return null;
    }
    nextSibling() {
        for (var n = this.currentNode.nextSibling; n; n = n.nextSibling) if (this[' accept'](n) === NodeFilter.FILTER_ACCEPT) { this.currentNode = n; return n }
        return null;
    }
    previousSibling() {
        for (var n = this.currentNode.previousSibling; n; n = n.previousSibling) if (this[' accept'](n) === NodeFilter.FILTER_ACCEPT) { this.currentNode = n; return n }
        return null;
    }
    get referenceNode() { return this.currentNode }
    detach() { }
}
def(global, 'TreeWalker', TreeWalker);
def(global, 'NodeIterator', TreeWalker);
class Range {
    constructor() {
        this.startContainer = document; this.startOffset = 0; this.endContainer = document; this.endOffset = 0; this.collapsed = true;
    }
    get commonAncestorContainer() { return this.startContainer }
    setStart(n, o) { this.startContainer = n; this.startOffset = o }
    setEnd(n, o) { this.endContainer = n; this.endOffset = o; this.collapsed = false }
    setStartBefore(n) { this.setStart(n.parentNode, 0) } setStartAfter(n) { this.setStart(n.parentNode, 0) }
    setEndBefore(n) { this.setEnd(n.parentNode, 0) } setEndAfter(n) { this.setEnd(n.parentNode, 0) }
    selectNode(n) { this.setStart(n, 0); this.setEnd(n, 0) }
    selectNodeContents(n) { this.setStart(n, 0); this.setEnd(n, n.childNodes.length) }
    collapse() { this.collapsed = true }
    cloneRange() { return Object.assign(new Range(), this) }
    detach() { }
    deleteContents() { }
    insertNode(n) { if (this.startContainer.nodeType === 1) this.startContainer.insertBefore(n, this.startContainer.childNodes[this.startOffset] || null) }
    getBoundingClientRect() { return rect(0, 0, 0, 0) }
    getClientRects() { return [] }
    toString() { return '' }
    createContextualFragment(html) {
        var t = document.createElement('div');
        t.innerHTML = html;
        var f = document.createDocumentFragment(), c;
        while ((c = t.firstChild)) nativeAppendChild.call(f, c);
        return f;
    }
}
def(global, 'Range', Range);
var selection = { rangeCount: 0, isCollapsed: true, type: 'None', anchorNode: null, focusNode: null, anchorOffset: 0, focusOffset: 0,
    getRangeAt: function () { return new Range() }, addRange: function () { }, removeAllRanges: function () { },
    removeRange: function () { }, collapse: function () { }, selectAllChildren: function () { }, empty: function () { },
    toString: function () { return '' }, containsNode: function () { return false } };

// --- the window's other parts ------------------------------------------------------------------
class Storage {
    getItem(k) { k = String(k); return Object.prototype.hasOwnProperty.call(this, k) ? this[k] : null }
    setItem(k, v) { this[String(k)] = String(v) }
    removeItem(k) { delete this[String(k)] }
    clear() { for (var k of Object.keys(this)) delete this[k] }
    key(i) { var keys = Object.keys(this); return i < keys.length ? keys[i] : null }
    get length() { return Object.keys(this).length }
}
def(global, 'Storage', Storage);
def(global, 'localStorage', new Storage());
def(global, 'sessionStorage', new Storage());

function mediaMatches(q) {
    q = String(q).toLowerCase();
    return q.split(',').some(function (part) {
        return part.split(/\band\b/).every(function (c) {
            c = c.trim();
            if (!c || c === 'all' || c === 'screen' || c === 'only screen') return true;
            if (c === 'print' || c === 'not all') return false;
            var m = /^\(\s*(min|max)-(width|height)\s*:\s*([\d.]+)(px|em|rem)?\s*\)$/.exec(c);
            if (m) {
                var v = Number(m[3]) * (m[4] === 'em' || m[4] === 'rem' ? 16 : 1);
                var size = m[2] === 'width' ? innerWidth : innerHeight;
                return m[1] === 'min' ? size >= v : size <= v;
            }
            if (/prefers-color-scheme\s*:\s*light/.test(c)) return true;
            if (/orientation\s*:\s*landscape/.test(c)) return innerWidth >= innerHeight;
            if (/orientation\s*:\s*portrait/.test(c)) return innerWidth < innerHeight;
            if (/hover\s*:\s*hover|pointer\s*:\s*fine/.test(c)) return true;
            return false;
        });
    });
}
class MediaQueryList extends EventTarget {
    constructor(q) { super(); this.media = String(q); this.matches = mediaMatches(q); this.onchange = null }
    addListener(fn) { this.addEventListener('change', fn) }
    removeListener(fn) { this.removeEventListener('change', fn) }
}
def(global, 'MediaQueryList', MediaQueryList);

// the observers: mutations are not reported; everything is visible and sized once
class MutationObserver {
    constructor(callback) { this[' cb'] = callback }
    observe() { }
    disconnect() { }
    takeRecords() { return [] }
}
function observeLater(self, target, entry) {
    setTimeout(function () {
        if (self[' targets'].indexOf(target) >= 0) self[' cb']([entry], self);
    }, 0);
}
class IntersectionObserver {
    constructor(callback, options) {
        this[' cb'] = callback; this[' targets'] = [];
        this.root = options && options.root || null; this.rootMargin = options && options.rootMargin || '0px';
        this.thresholds = [].concat(options && options.threshold || 0);
    }
    observe(target) {
        this[' targets'].push(target);
        var r = target.getBoundingClientRect();
        observeLater(this, target, { target: target, isIntersecting: true, intersectionRatio: 1, boundingClientRect: r,
            intersectionRect: r, rootBounds: rect(0, 0, innerWidth, innerHeight), time: performance.now() });
    }
    unobserve(target) { var i = this[' targets'].indexOf(target); if (i >= 0) this[' targets'].splice(i, 1) }
    disconnect() { this[' targets'] = [] }
    takeRecords() { return [] }
}
class ResizeObserver {
    constructor(callback) { this[' cb'] = callback; this[' targets'] = [] }
    observe(target) {
        this[' targets'].push(target);
        var r = target.getBoundingClientRect(), box = [{ inlineSize: r.width, blockSize: r.height }];
        observeLater(this, target, { target: target, contentRect: r, borderBoxSize: box, contentBoxSize: box, devicePixelContentBoxSize: box });
    }
    unobserve(target) { var i = this[' targets'].indexOf(target); if (i >= 0) this[' targets'].splice(i, 1) }
    disconnect() { this[' targets'] = [] }
}
class PerformanceObserver {
    constructor(callback) { }
    observe() { } disconnect() { } takeRecords() { return [] }
}
PerformanceObserver.supportedEntryTypes = [];
def(global, 'MutationObserver', MutationObserver);
def(global, 'WebKitMutationObserver', MutationObserver);
def(global, 'IntersectionObserver', IntersectionObserver);
def(global, 'ResizeObserver', ResizeObserver);
def(global, 'PerformanceObserver', PerformanceObserver);

// the style a script sees: the inline style, then defaults for the tag
var inlineTags = /^(A|ABBR|B|BDI|BDO|BR|CITE|CODE|DATA|DFN|EM|I|IMG|INPUT|KBD|LABEL|MARK|Q|S|SAMP|SELECT|SMALL|SPAN|STRONG|SUB|SUP|TEXTAREA|TIME|U|VAR|BUTTON|SVG)$/;
function computedStyle(el) {
    var inline = el && el.style;
    var defaults = { display: !el || el.nodeType !== 1 ? 'block' : el.hidden ? 'none' : el.tagName === 'LI' ? 'list-item' : inlineTags.test(el.tagName) ? 'inline' : /^(SCRIPT|STYLE|HEAD|TITLE|META|LINK|TEMPLATE)$/.test(el.tagName) ? 'none' : 'block',
        visibility: 'visible', opacity: '1', position: 'static', float: 'none', overflow: 'visible', overflowX: 'visible', overflowY: 'visible',
        boxSizing: 'content-box', direction: 'ltr', color: 'rgb(0, 0, 0)', backgroundColor: 'rgba(0, 0, 0, 0)',
        fontSize: '16px', fontFamily: 'sans-serif', fontWeight: '400', lineHeight: 'normal', zIndex: 'auto',
        transform: 'none', transitionDuration: '0s', animationDuration: '0s', animationName: 'none', pointerEvents: 'auto',
        width: el && el.offsetWidth + 'px', height: el && el.offsetHeight + 'px', cursor: 'auto', content: 'normal',
        marginTop: '0px', marginRight: '0px', marginBottom: '0px', marginLeft: '0px',
        paddingTop: '0px', paddingRight: '0px', paddingBottom: '0px', paddingLeft: '0px',
        borderTopWidth: '0px', borderRightWidth: '0px', borderBottomWidth: '0px', borderLeftWidth: '0px' };
    function value(prop) {
        var v = inline ? inline[prop] : '';
        if (v) return v;
        return defaults[prop] !== undefined ? defaults[prop] : '';
    }
    var s = {
        getPropertyValue: function (name) { return value(camel(String(name))) },
        getPropertyPriority: function () { return '' },
        item: function (i) { return Object.keys(defaults).map(kebab)[i] || '' },
    };
    for (var p of Object.keys(defaults)) (function (p) { Object.defineProperty(s, p, { get: function () { return value(p) }, enumerable: true }) })(p);
    Object.defineProperty(s, 'length', { value: Object.keys(defaults).length });
    return s;
}

var historyState = null, historyLength = 1;
var history = {
    get length() { return historyLength },
    get state() { return historyState },
    scrollRestoration: 'auto',
    pushState: function pushState(state) { historyState = state; historyLength++ },
    replaceState: function replaceState(state) { historyState = state },
    back: function back() { }, forward: function forward() { }, go: function go() { },
};
var screen = { width: innerWidth, height: innerHeight, availWidth: innerWidth, availHeight: innerHeight,
    availTop: 0, availLeft: 0, colorDepth: 24, pixelDepth: 24,
    orientation: { type: 'landscape-primary', angle: 0, addEventListener: function () { }, removeEventListener: function () { } } };
var idleId = 0, idleTimers = {};
var crypto = {
    getRandomValues: function getRandomValues(a) {
        var max = a.BYTES_PER_ELEMENT ? Math.pow(2, 8 * a.BYTES_PER_ELEMENT) : 256;
        for (var i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * max);
        return a;
    },
    randomUUID: function randomUUID() {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
            var r = Math.random() * 16 | 0;
            return (c === 'x' ? r : r & 3 | 8).toString(16);
        });
    },
    subtle: {},
};
var nav = global.navigator;
defAll(nav, {
    platform: 'Antigravity', vendor: '', appName: 'Netscape', appVersion: '5.0 (Antigravity OS)', product: 'Gecko',
    languages: [nav.language], onLine: true, cookieEnabled: true, hardwareConcurrency: 1, maxTouchPoints: 0,
    doNotTrack: null, webdriver: false, pdfViewerEnabled: false,
    sendBeacon: function sendBeacon() { return true },
    vibrate: function vibrate() { return false },
    javaEnabled: function javaEnabled() { return false },
    clipboard: { writeText: function () { return Promise.resolve() }, readText: function () { return Promise.resolve('') } },
    permissions: { query: function () { return Promise.resolve({ state: 'denied', onchange: null }) } },
    mediaDevices: { enumerateDevices: function () { return Promise.resolve([]) } },
    userAgentData: { brands: [], mobile: false, platform: 'Antigravity', getHighEntropyValues: function () { return Promise.resolve({}) } },
});
var customElementsRegistry = new Map();
class DOMException extends Error {
    constructor(message, name) {
        super(message);
        def(this, 'name', name || 'Error');
    }
}
def(global, 'DOMException', DOMException);

defAll(global, {
    window: global, self: global, frames: global, top: global, parent: global, globalThis: global,
    opener: null, frameElement: null, closed: false, name: '', status: '', length: 0,
    origin: location.protocol + '//' + location.host,
    isSecureContext: location.protocol === 'https:',
    devicePixelRatio: 1, scrollX: 0, scrollY: 0, pageXOffset: 0, pageYOffset: 0, screenX: 0, screenY: 0, screenLeft: 0, screenTop: 0,
    outerWidth: innerWidth, outerHeight: innerHeight,
    history: history, screen: screen, crypto: crypto,
    visualViewport: { width: innerWidth, height: innerHeight, scale: 1, offsetLeft: 0, offsetTop: 0, pageLeft: 0, pageTop: 0,
        addEventListener: function () { }, removeEventListener: function () { } },
    scroll: function scroll() { }, scrollTo: function scrollTo() { }, scrollBy: function scrollBy() { },
    open: function open() { return null }, close: function close() { }, print: function print() { }, stop: function stop() { },
    focus: function focus() { }, blur: function blur() { }, moveTo: function moveTo() { }, resizeTo: function resizeTo() { },
    getComputedStyle: function getComputedStyle(el) { return computedStyle(el) },
    matchMedia: function matchMedia(q) { return new MediaQueryList(q) },
    getSelection: function getSelection() { return selection },
    requestIdleCallback: function requestIdleCallback(cb) {
        var id = ++idleId;
        idleTimers[id] = setTimeout(function () {
            delete idleTimers[id];
            cb({ didTimeout: false, timeRemaining: function () { return 50 } });
        }, 1);
        return id;
    },
    cancelIdleCallback: function cancelIdleCallback(id) { clearTimeout(idleTimers[id]); delete idleTimers[id] },
    postMessage: function postMessage(data, origin) {
        setTimeout(function () {
            global.dispatchEvent(new MessageEvent('message', { data: data, origin: global.origin, source: global }));
        }, 0);
    },
    customElements: {
        define: function define(name, C) { customElementsRegistry.set(name, C) },
        get: function get(name) { return customElementsRegistry.get(name) },
        whenDefined: function whenDefined(name) { return Promise.resolve(customElementsRegistry.get(name)) },
        upgrade: function upgrade() { },
    },
    CSS: {
        supports: function supports() { return false },
        escape: function escape(s) { return String(s).replace(/([^\w-])/g, '\\$1').replace(/^(\d)/, '\\3$1 ') },
    },
    Image: function Image(w, h) {
        var img = document.createElement('img');
        if (w !== undefined) img.setAttribute('width', w);
        if (h !== undefined) img.setAttribute('height', h);
        return img;
    },
    Option: function Option(text, value, dflt, selected) {
        var o = document.createElement('option');
        if (text !== undefined) o.textContent = text;
        if (value !== undefined) o.setAttribute('value', value);
        if (selected) o.setAttribute('selected', '');
        return o;
    },
    DOMParser: class DOMParser {
        parseFromString(s, type) { return detachedDocument(s) }
    },
    XMLSerializer: class XMLSerializer {
        serializeToString(n) { return n.nodeType === 1 ? n.outerHTML : n.nodeType === 9 ? n.documentElement.outerHTML : n.textContent }
    },
});

// performance: the navigation's times (all at the start), no entries
var perf = global.performance, origin = Date.now() - perf.now();
var timing = {};
['navigationStart', 'fetchStart', 'domainLookupStart', 'domainLookupEnd', 'connectStart', 'connectEnd', 'requestStart',
 'responseStart', 'responseEnd', 'domLoading', 'domInteractive', 'domContentLoadedEventStart', 'domContentLoadedEventEnd',
 'domComplete', 'loadEventStart', 'loadEventEnd', 'unloadEventStart', 'unloadEventEnd', 'redirectStart', 'redirectEnd',
 'secureConnectionStart'].forEach(function (k) { timing[k] = origin });
defAll(perf, {
    timeOrigin: origin, timing: timing,
    navigation: { type: 0, redirectCount: 0 },
    memory: { usedJSHeapSize: 0, totalJSHeapSize: 0, jsHeapSizeLimit: 0 },
    getEntries: function getEntries() { return [] },
    getEntriesByType: function getEntriesByType() { return [] },
    getEntriesByName: function getEntriesByName() { return [] },
    mark: function mark(name) { return { name: name, entryType: 'mark', startTime: perf.now(), duration: 0 } },
    measure: function measure(name) { return { name: name, entryType: 'measure', startTime: 0, duration: perf.now() } },
    clearMarks: function clearMarks() { }, clearMeasures: function clearMeasures() { },
    clearResourceTimings: function clearResourceTimings() { }, setResourceTimingBufferSize: function () { },
    toJSON: function toJSON() { return { timeOrigin: origin } },
});

// MessageChannel: a message posted on one port arrives at the other as a task
class MessagePort extends EventTarget {
    constructor() { super(); this.onmessage = null; def(this, ' other', null) }
    postMessage(data) {
        var other = this[' other'];
        if (!other) return;
        setTimeout(function () { other.dispatchEvent(new MessageEvent('message', { data: data })) }, 0);
    }
    start() { }
    close() { def(this, ' other', null) }
}
class MessageChannel {
    constructor() {
        this.port1 = new MessagePort();
        this.port2 = new MessagePort();
        def(this.port1, ' other', this.port2);
        def(this.port2, ' other', this.port1);
    }
}
def(global, 'MessagePort', MessagePort);
def(global, 'MessageChannel', MessageChannel);
class BroadcastChannel extends EventTarget {
    constructor(name) { super(); this.name = String(name); this.onmessage = null }
    postMessage() { }
    close() { }
}
def(global, 'BroadcastChannel', BroadcastChannel);

// FormData, Blob, File, FileReader
class FormData {
    constructor(form) {
        def(this, ' list', []);
        if (form && form.querySelectorAll) {
            for (var el of form.querySelectorAll('input, select, textarea')) {
                var n = el.getAttribute('name');
                if (!n || el.disabled) continue;
                var t = (el.getAttribute('type') || '').toLowerCase();
                if ((t === 'checkbox' || t === 'radio') && !el.checked) continue;
                this.append(n, el.value);
            }
        }
    }
    append(k, v) { this[' list'].push([String(k), v]) }
    delete(k) { k = String(k); def(this, ' list', this[' list'].filter(function (p) { return p[0] !== k })) }
    get(k) { k = String(k); for (var p of this[' list']) if (p[0] === k) return p[1]; return null }
    getAll(k) { k = String(k); return this[' list'].filter(function (p) { return p[0] === k }).map(function (p) { return p[1] }) }
    has(k) { return this.get(k) !== null }
    set(k, v) { this.delete(k); this.append(k, v) }
    forEach(fn, self) { for (var p of this[' list']) fn.call(self, p[1], p[0], this) }
    entries() { return this[' list'].map(function (p) { return [p[0], p[1]] })[Symbol.iterator]() }
    keys() { return this[' list'].map(function (p) { return p[0] })[Symbol.iterator]() }
    values() { return this[' list'].map(function (p) { return p[1] })[Symbol.iterator]() }
    [Symbol.iterator]() { return this.entries() }
}
class Blob {
    constructor(parts, options) {
        def(this, ' text', (parts || []).map(function (p) { return p instanceof Blob ? p[' text'] : String(p) }).join(''));
        this.type = options && options.type ? String(options.type).toLowerCase() : '';
    }
    get size() { return this[' text'].length }
    text() { return Promise.resolve(this[' text']) }
    slice(a, b, type) { return new Blob([this[' text'].slice(a, b)], { type: type }) }
}
class File extends Blob {
    constructor(parts, name, options) { super(parts, options); this.name = String(name); this.lastModified = Date.now() }
}
class FileReader extends EventTarget {
    constructor() { super(); this.result = null; this.readyState = 0; this.error = null; this.onload = null; this.onloadend = null }
    readAsText(blob) {
        var self = this;
        setTimeout(function () {
            self.result = blob[' text']; self.readyState = 2;
            self.dispatchEvent(new ProgressEvent('load'));
            self.dispatchEvent(new ProgressEvent('loadend'));
        }, 0);
    }
    readAsDataURL(blob) {
        var self = this;
        setTimeout(function () {
            self.result = 'data:' + (blob.type || 'application/octet-stream') + ';base64,' + btoa(blob[' text']); self.readyState = 2;
            self.dispatchEvent(new ProgressEvent('load'));
            self.dispatchEvent(new ProgressEvent('loadend'));
        }, 0);
    }
    abort() { }
}
def(global, 'FormData', FormData);
def(global, 'Blob', Blob);
def(global, 'File', File);
def(global, 'FileReader', FileReader);

})(globalThis);
