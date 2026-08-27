"""What one animated canvas frame costs a PYTHON guest, phase by phase.

THE SCENE is the one docs/measurements/canvas-marshal-2026-08-26.txt
records: 341 paths, 2886 ops, 8296 wire values, over an 800x600 viewbox.
It is the scene the canvas research measured through a standalone Rust
mirror at 0.019 ms; this file measures the same frame through the REAL
binding — kaya.Draw, kaya.wire.tx_set_drawing, kaya.runtime.submit —
so the two numbers answer the same question.

FOUR PHASES, timed separately, because the packed-encoding lane would
remove some and not others:

  build    the Draw recorder's op list (per-op Python objects)
  encode   tx_set_drawing: struct.pack per value into one bytes
  submit   b"".join + kaya_submit: the FFI hop and the core's
           decode_transaction, on the calling thread
  frame    the whole real spelling, `with app.build(): with h.draw()`

THREE SIZES AND A GROWTH RATIO, the shape bindings/python/kaya_app_checks.py's
Bulk clause uses: a marshal path that is linear in ops holds near 1.00x
per op, and anything else is the finding. The 16x size is deliberately
past a frame budget — that is where the crossover gets read off rather
than extrapolated.

NO WINDOW IS EVER SHOWN: kaya_run is never called, so the submitted
transactions queue in the core's channel and the process exits. That
also means the memory the queue holds is reported below rather than
ignored.
"""

import os
import pathlib
import resource
import statistics
import sys
import time

ROOT = pathlib.Path(os.environ["KAYA_ROOT"]).resolve()
sys.path.insert(0, str(ROOT / "bindings" / "python"))

import kaya                                    # noqa: E402
from kaya import runtime, wire                 # noqa: E402

VIEWBOX = (800.0, 600.0)
# The five paint ROLES the core's vocabulary actually has
# (crates/kaya/src/spec.rs). The Rust mirror pushed raw palette indices
# 0..7, which the real core refuses; the op count and the value count
# are identical either way, and those are what a marshal costs.
ROLES = ("series", "series_fill", "grid", "axis", "ground")


def emit(d, t, copies=1):
    """One frame into an already-open Draw recorder.

    Ported op-for-op from the Rust mirror: 1 background fill, 40 stroked
    gridlines, 180 filled octagons, 120 stroked 7-point polylines.
    `copies` repeats the whole scene, which is how the second size is
    made without changing the op MIX.
    """
    import math
    for c in range(copies):
        tt = t + c * 0.3
        # background: 4 point ops, close, fill
        d.move_to(0.0, 0.0)
        d.line_to(800.0, 0.0)
        d.line_to(800.0, 600.0)
        d.line_to(0.0, 600.0)
        d.close()
        d.fill("ground")
        # gridlines: 40 x (move, line, stroke)
        for i in range(40):
            x = i * 20.0
            d.move_to(x, 0.0)
            d.line_to(x, 600.0)
            d.stroke("grid", 1.0)
        # particles: 180 octagons
        for i in range(180):
            a = i * 0.7 + tt
            cx = 400.0 + 340.0 * math.sin(a * 0.9)
            cy = 300.0 + 250.0 * math.cos(a * 1.3)
            r = 6.0 + 12.0 * (math.sin(a * 2.1) * 0.5 + 0.5)
            for k in range(8):
                th = k * math.tau / 8.0 + a
                x, y = cx + r * math.cos(th), cy + r * math.sin(th)
                if k == 0:
                    d.move_to(x, y)
                else:
                    d.line_to(x, y)
            d.close()
            d.fill(ROLES[i % 5])
        # trails: 120 polylines of 7 points
        for i in range(120):
            a = i * 0.51 + tt * 1.7
            for k in range(7):
                u = a + k * 0.25
                x = 400.0 + 360.0 * math.sin(u * 0.8)
                y = 300.0 + 260.0 * math.cos(u * 1.1)
                if k == 0:
                    d.move_to(x, y)
                else:
                    d.line_to(x, y)
            d.stroke(ROLES[i % 5], 1.5)


def stats(xs):
    xs = sorted(xs)
    return xs[0], statistics.median(xs), xs[(len(xs) * 95) // 100]


def bench(name, reps, fn, ops):
    for i in range(max(3, reps // 10)):
        fn(i * 0.11)
    xs = []
    for i in range(reps):
        t = i * 0.037
        s = time.perf_counter()
        fn(t)
        xs.append((time.perf_counter() - s) * 1000.0)
    lo, med, p95 = stats(xs)
    print(f"  {name:<34} min {lo:8.3f}  med {med:8.3f}  p95 {p95:8.3f} ms"
          f"   [{med / 16.6 * 100:6.1f}% of 16.6ms]"
          f"   {med * 1000 / ops:7.3f} us/op")
    return med


def rss_mb():
    # macOS reports ru_maxrss in BYTES, linux in kilobytes.
    n = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return n / (1024 * 1024) if sys.platform == "darwin" else n / 1024


app = kaya.App()
with app.window(title="marshal bench", width=800, height=600):
    with kaya.column():
        cv = kaya.canvas(VIEWBOX)

# One reference frame, to state the scene's own size rather than assert it.
ref = kaya.Draw(VIEWBOX)
emit(ref, 0.0)
OPS_1X = 2886
print(f"scene: viewbox 800x600, {len(ref._ops)} wire values, "
      f"{OPS_1X} ops, 341 paths")
rec = wire.tx_set_drawing(cv.id, VIEWBOX[0], VIEWBOX[1],
                          len(ref._ops), 0, [*ref._ops])
print(f"one set_drawing record on the wire: {len(rec)} bytes\n")

for copies, reps in ((1, 150), (4, 60), (16, 30)):
    ops = OPS_1X * copies
    print(f"== {copies}x the scene: {ops} ops, "
          f"{len(ref._ops) * copies} wire values, {reps} timed frames ==")

    def do_build(t, copies=copies):
        d = kaya.Draw(VIEWBOX)
        emit(d, t, copies)
        return d

    prebuilt = do_build(0.3)._ops

    def do_encode(t, copies=copies, ops_list=prebuilt):
        # The list splice is the draw scope's own line
        # (`[*self._keys, *ops]`), so it is timed with the encode.
        return wire.tx_set_drawing(cv.id, VIEWBOX[0], VIEWBOX[1],
                                   len(ops_list), 0, [*ops_list])

    record = do_encode(0.0)

    def do_submit(t, r=record):
        runtime.submit(r)

    def do_frame(t, copies=copies):
        with app.build():
            with cv.draw() as d:
                emit(d, t, copies)

    b = bench("build (Draw op list)", reps, do_build, ops)
    e = bench("encode (tx_set_drawing)", reps, do_encode, ops)
    s = bench("submit (join+FFI+core decode)", reps, do_submit, ops)
    f = bench("FRAME (build+encode+submit)", reps, do_frame, ops)
    print(f"  phases sum {b + e + s:.3f} ms vs measured frame {f:.3f} ms")
    print(f"  peak RSS after this size: {rss_mb():.0f} MB\n")

print("NOTE: every submit above queues a decoded transaction in the core's "
      "channel\n      (no UI thread drains it here) — that is what the RSS "
      "line accounts for.")
