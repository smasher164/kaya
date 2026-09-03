// Same wire records, but a SINGLE growable buffer written at a cursor —
// no per-scalar Uint8Array, no per-scalar DataView. The question this answers:
// how much of the JIT-less penalty is the encoder's shape rather than the engine's?
var out = (typeof print === "function") ? print : console.log;
var now = Date.now;
var buf = new Uint8Array(1 << 20), view = new DataView(buf.buffer), at = 0;
function ensure(n) {
  if (at + n <= buf.length) return;
  var cap = buf.length; while (cap < at + n) cap *= 2;
  var nb = new Uint8Array(cap); nb.set(buf.subarray(0, at), 0);
  buf = nb; view = new DataView(buf.buffer);
}
function u32(v) { ensure(4); view.setUint32(at, v, true); at += 4; }
function u64(v) { ensure(8); view.setUint32(at, v % 4294967296, true); view.setUint32(at + 4, Math.floor(v / 4294967296), true); at += 8; }
function f64(v) { ensure(8); view.setFloat64(at, v, true); at += 8; }
function padTo8() { var r = at % 8; if (r) { ensure(8 - r); at += 8 - r; } }
function str(s) {
  ensure(s.length * 3 + 8);
  var lenAt = at; at += 4;              // length patched after
  var n = s.length, c, start = at;
  for (var i = 0; i < n; i++) {
    c = s.charCodeAt(i);
    if (c < 0x80) buf[at++] = c;
    else if (c < 0x800) { buf[at++] = 0xc0 | (c >> 6); buf[at++] = 0x80 | (c & 63); }
    else { buf[at++] = 0xe0 | (c >> 12); buf[at++] = 0x80 | ((c >> 6) & 63); buf[at++] = 0x80 | (c & 63); }
  }
  view.setUint32(lenAt, at - start, true);
}
function record(kind, body) {           // body is a closure writing the payload
  var head = at; ensure(8); at += 8;
  body(); padTo8();
  view.setUint32(head, at - head, true);
  view.setUint16(head + 4, kind, true);
  view.setUint16(head + 6, 0, true);
}
function packBatch(n) {
  at = 0;
  for (var i = 0; i < n; i++) {
    if (i & 1) {
      (function (i) { record(7, function () { u64(1000 + i); u32(2); u32(8); f64(i * 1.5); }); })(i);
    } else {
      (function (i) { record(12, function () { u64(2000 + i); u32(3); str("row " + i + " of the ledger"); padTo8(); }); })(i);
    }
  }
  return at;
}
function timed(fn, arg, reps) { var best = Infinity, t, i; for (i = 0; i < reps; i++) { t = now(); fn(arg); t = now() - t; if (t < best) best = t; } return best; }
timed(packBatch, 200, 50);
var big = 15003, reps = 40, t = 0, i;
for (i = 0; i < reps; i++) { var s = now(); packBatch(big); t += now() - s; }
out("cursor15003\t" + (t / reps).toFixed(2) + " ms/batch\t" + ((t / reps) * 1000 / big).toFixed(3) + " us/record\t(bytes " + packBatch(big) + ")");
var reps2 = 20000, t2 = now();
for (i = 0; i < reps2; i++) packBatch(20);
t2 = now() - t2;
out("cursorHandler20\t" + (t2 * 1000 / reps2).toFixed(2) + " us/batch");
