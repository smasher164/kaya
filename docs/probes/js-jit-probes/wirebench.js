// kaya wire-packing micro-benchmark, portable across node / jsc / qjs / hermes.
// Mirrors bindings/js/kaya/wire.ts exactly: per-scalar Uint8Array + DataView,
// cat() concatenation, pad() to 8, record() framing.
var out = (typeof print === "function") ? print : console.log;
var now = Date.now;

// ---- the encoder, transliterated from wire.ts ----
function cat() {
  var parts = arguments, n = 0, i, at = 0;
  for (i = 0; i < parts.length; i++) n += parts[i].length;
  var o = new Uint8Array(n);
  for (i = 0; i < parts.length; i++) { o.set(parts[i], at); at += parts[i].length; }
  return o;
}
function pad(b) {
  var r = b.length % 8;
  if (r === 0) return b;
  var o = new Uint8Array(b.length + (8 - r));
  o.set(b, 0);
  return o;
}
function u32(v) { var b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, v, true); return b; }
function u64(v) {
  var b = new Uint8Array(8), view = new DataView(b.buffer);
  view.setUint32(0, v % 4294967296, true);
  view.setUint32(4, Math.floor(v / 4294967296), true);
  return b;
}
function f64(v) { var b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0, v, true); return b; }
// pure-JS UTF-8 so every engine runs identical work (no TextEncoder in a bare JSC)
function utf8(s) {
  var n = s.length, b = new Uint8Array(n * 3), at = 0, i, c;
  for (i = 0; i < n; i++) {
    c = s.charCodeAt(i);
    if (c < 0x80) { b[at++] = c; }
    else if (c < 0x800) { b[at++] = 0xc0 | (c >> 6); b[at++] = 0x80 | (c & 63); }
    else { b[at++] = 0xe0 | (c >> 12); b[at++] = 0x80 | ((c >> 6) & 63); b[at++] = 0x80 | (c & 63); }
  }
  return b.subarray(0, at);
}
var VALUE_BOOL = 0, VALUE_I64 = 1, VALUE_F64 = 2, VALUE_STR = 3;
function encValue(v) {
  if (typeof v === "boolean") return pad(cat(u32(VALUE_BOOL), u32(1), new Uint8Array([v ? 1 : 0])));
  if (typeof v === "number") return cat(u32(VALUE_F64), u32(8), f64(v));
  if (typeof v === "string") { var s = utf8(v); return pad(cat(u32(VALUE_STR), u32(s.length), s)); }
  throw new TypeError("not a wire value");
}
function record(kind, body) {
  body = pad(body);
  var head = new Uint8Array(8), view = new DataView(head.buffer);
  view.setUint32(0, 8 + body.length, true);
  view.setUint16(4, kind, true);
  view.setUint16(6, 0, true);
  return cat(head, body);
}
function tx_write_signal(id, v) { return record(7, cat(u64(id), encValue(v))); }
function tx_set_text(id, s) { return record(12, cat(u64(id), encValue(s))); }

// ---- benchmark 1: pack N records and concatenate into one batch ----
function packBatch(n) {
  var recs = new Array(n), i, total = 0;
  for (i = 0; i < n; i++) {
    recs[i] = (i & 1) ? tx_write_signal(1000 + i, i * 1.5)
                      : tx_set_text(2000 + i, "row " + i + " of the ledger");
    total += recs[i].length;
  }
  var buf = new Uint8Array(total), at = 0;
  for (i = 0; i < n; i++) { buf.set(recs[i], at); at += recs[i].length; }
  return buf.length;
}

// ---- benchmark 2: JIT canary — pure integer arithmetic ----
function canary(iters) {
  var x = 0, i;
  for (i = 0; i < iters; i++) { x = (x + i * 3) | 0; x = (x ^ (x >>> 7)) | 0; }
  return x;
}

// ---- benchmark 3: monomorphic typed-array write loop (memory-bound control) ----
function tawrite(iters) {
  var b = new Uint8Array(1 << 16), v = new DataView(b.buffer), i;
  for (i = 0; i < iters; i++) v.setUint32((i & 16380), i, true);
  return b[0];
}

function bench(name, fn, arg, reps) {
  var best = Infinity, t, i, r;
  for (i = 0; i < reps; i++) { t = now(); r = fn(arg); t = now() - t; if (t < best) best = t; }
  out(name + "\t" + best + " ms\t(result " + r + ")");
}

var N = 100000;
out("engine\t" + (typeof process !== "undefined" && process.versions ? "node " + process.versions.node
    : (typeof navigator !== "undefined" && navigator.userAgent ? navigator.userAgent : "unknown")));
bench("pack100k", packBatch, N, 5);
bench("canary50M", canary, 50000000, 3);
bench("tawrite20M", tawrite, 20000000, 3);
