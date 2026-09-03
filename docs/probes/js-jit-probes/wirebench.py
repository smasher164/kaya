"""kaya's PYTHON wire encoder, transliterated from bindings/python/kaya/wire.py,
packing the same records as wirebench.js — the shipped-interpreter baseline."""
import struct, time

def _pad(b):
    r = len(b) % 8
    return b if r == 0 else b + b"\0" * (8 - r)

VALUE_BOOL, VALUE_I64, VALUE_F64, VALUE_STR = 0, 1, 2, 3

def value(v):
    if isinstance(v, bool):
        return _pad(struct.pack("<II", VALUE_BOOL, 1) + bytes([v]))
    if isinstance(v, float):
        return struct.pack("<IId", VALUE_F64, 8, v)
    if isinstance(v, int):
        return struct.pack("<IIq", VALUE_I64, 8, v)
    utf8 = v.encode()
    return _pad(struct.pack("<II", VALUE_STR, len(utf8)) + utf8)

def record(kind, body):
    body = _pad(body)
    return struct.pack("<IHH", 8 + len(body), kind, 0) + body

def tx_write_signal(sid, v): return record(7, struct.pack("<Q", sid) + value(v))
def tx_set_text(wid, s):     return record(12, struct.pack("<Q", wid) + value(s))

def pack_batch(n):
    parts = []
    for i in range(n):
        parts.append(tx_write_signal(1000 + i, i * 1.5) if i & 1
                     else tx_set_text(2000 + i, "row %d of the ledger" % i))
    return len(b"".join(parts))

pack_batch(200)
big, reps = 15003, 20
t = time.perf_counter()
for _ in range(reps): pack_batch(big)
d = (time.perf_counter() - t) / reps * 1000
print("py portfolio15003\t%.2f ms/batch\t%.3f us/record" % (d, d * 1000 / big))
reps2, small = 5000, 20
t = time.perf_counter()
for _ in range(reps2): pack_batch(small)
d2 = (time.perf_counter() - t) / reps2 * 1e6
print("py handler20    \t%.2f us/batch" % d2)
