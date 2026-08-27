package dev.kaya;

import java.util.Arrays;
import java.util.List;

/**
 * What one animated canvas frame costs a JAVA guest, phase by phase —
 * the twin of the Python guest, over the same 341-path / 2886-op /
 * 8296-value scene.
 *
 * <p>IN PACKAGE dev.kaya so the phases can be split honestly: the Draw
 * recorder's constructor and its {@code ops} list are package-private,
 * and timing "build" without them would mean timing the whole
 * transaction instead.
 *
 * <p>NO WINDOW IS EVER SHOWN: KayaRing.run() is never called, so the
 * submitted transactions queue in the core's channel and the process
 * exits.
 *
 * <p>RUN AGAINST THE TREE'S OWN KayaWire IT PRINTS A CEILING AND STOPS:
 * KayaWire.begin allocates a fixed 4096-byte ByteBuffer, so a
 * full-frame set_drawing (132,800 bytes) throws BufferOverflowException
 * before anything can be timed. That is the watched negative, and the
 * numbers in docs/measurements/canvas-marshal-2026-08-26.txt were taken
 * with a scratch copy of KayaWire whose begin sizes the buffer from the
 * value count. Keep the probe until the ceiling is gone.
 */
public final class CanvasMarshalBench {
    private static final KayaApp.Viewbox VIEWBOX = new KayaApp.Viewbox(800.0, 600.0);
    private static final KayaApp.Paint[] ROLES = {
        KayaApp.Paint.SERIES, KayaApp.Paint.SERIES_FILL, KayaApp.Paint.GRID,
        KayaApp.Paint.AXIS, KayaApp.Paint.GROUND,
    };
    private static final int OPS_1X = 2886;

    /** One frame into an already-open Draw recorder, op for op the
     * Python and Rust guests' scene. */
    static void emit(KayaApp.Draw d, double t0, int copies) {
        for (int c = 0; c < copies; c++) {
            double t = t0 + c * 0.3;
            d.moveTo(0.0, 0.0)
                .lineTo(800.0, 0.0)
                .lineTo(800.0, 600.0)
                .lineTo(0.0, 600.0)
                .close()
                .fill(KayaApp.Paint.GROUND, KayaApp.FillRule.NONZERO);
            for (int i = 0; i < 40; i++) {
                double x = i * 20.0;
                d.moveTo(x, 0.0).lineTo(x, 600.0).stroke(KayaApp.Paint.GRID, 1.0);
            }
            for (int i = 0; i < 180; i++) {
                double a = i * 0.7 + t;
                double cx = 400.0 + 340.0 * Math.sin(a * 0.9);
                double cy = 300.0 + 250.0 * Math.cos(a * 1.3);
                double r = 6.0 + 12.0 * (Math.sin(a * 2.1) * 0.5 + 0.5);
                for (int k = 0; k < 8; k++) {
                    double th = k * (2.0 * Math.PI) / 8.0 + a;
                    double x = cx + r * Math.cos(th);
                    double y = cy + r * Math.sin(th);
                    if (k == 0) {
                        d.moveTo(x, y);
                    } else {
                        d.lineTo(x, y);
                    }
                }
                d.close().fill(ROLES[i % 5], KayaApp.FillRule.NONZERO);
            }
            for (int i = 0; i < 120; i++) {
                double a = i * 0.51 + t * 1.7;
                for (int k = 0; k < 7; k++) {
                    double u = a + k * 0.25;
                    double x = 400.0 + 360.0 * Math.sin(u * 0.8);
                    double y = 300.0 + 260.0 * Math.cos(u * 1.1);
                    if (k == 0) {
                        d.moveTo(x, y);
                    } else {
                        d.lineTo(x, y);
                    }
                }
                d.stroke(ROLES[i % 5], 1.5);
            }
        }
    }

    interface Frame {
        void run(double t);
    }

    private static double bench(String name, int warmup, int reps, Frame f, int ops) {
        for (int i = 0; i < warmup; i++) {
            f.run(i * 0.11);
        }
        // A collection BEFORE the timed window rather than inside it:
        // these phases allocate heavily and an unattributed G1 pause is
        // the difference between the phase sums agreeing and not.
        System.gc();
        double[] xs = new double[reps];
        for (int i = 0; i < reps; i++) {
            long s = System.nanoTime();
            f.run(i * 0.037);
            xs[i] = (System.nanoTime() - s) / 1_000_000.0;
        }
        Arrays.sort(xs);
        double lo = xs[0];
        double med = xs[reps / 2];
        double p95 = xs[(reps * 95) / 100];
        System.out.printf(
            "  %-34s min %8.3f  med %8.3f  p95 %8.3f ms   [%6.1f%% of 16.6ms]   %7.3f us/op%n",
            name, lo, med, p95, med / 16.6 * 100.0, med * 1000.0 / ops);
        return med;
    }

    private static long heapMb() {
        Runtime r = Runtime.getRuntime();
        return (r.totalMemory() - r.freeMemory()) / (1024 * 1024);
    }

    public static void main(String[] args) {
        String lib = System.getenv("KAYA_LIB");
        if (lib != null) {
            System.load(lib);
        } else {
            System.loadLibrary("kaya");
        }
        KayaRing.attach();

        KayaApp app = new KayaApp();
        KayaApp.Widget canvas = app.build(
            (java.util.function.Function<KayaApp.Tx, KayaApp.Widget>)
                tx -> tx.canvas(VIEWBOX));

        KayaApp.Draw ref = new KayaApp.Draw(VIEWBOX);
        emit(ref, 0.0, 1);
        System.out.printf("scene: viewbox 800x600, %d wire values, %d ops, 341 paths%n",
            ref.ops.size(), OPS_1X);

        // THE CEILING, WATCHED: this is the whole point of running the
        // unpatched binding first. A set_drawing record for this scene is
        // ~133 KB and KayaWire.begin allocates a fixed 4096-byte
        // ByteBuffer, so the encode throws before anything can be timed.
        if (System.getenv("KAYA_BENCH_SKIP_CEILING") == null) {
            try {
                KayaWire.txSetDrawing(canvas.id, 800.0, 600.0,
                    ref.ops.size(), 0, ref.ops.toArray());
                System.out.println("CEILING: txSetDrawing ACCEPTED the full scene "
                    + "(the 4096-byte buffer is gone)");
            } catch (RuntimeException e) {
                System.out.println("CEILING: txSetDrawing REFUSED the full scene — "
                    + e.getClass().getName()
                    + " (KayaWire.begin's fixed ByteBuffer.allocate(4096))");
                System.out.println("  the biggest scene this binding CAN encode: "
                    + biggestEncodable(canvas.id) + " wire values");
                // THE CEILING IS THE RECORD ENCODER'S, NOT THE CANVAS'S.
                // Same bisection over a plain text prop, so the report
                // can say how wide the blast radius is.
                System.out.println("  the longest text txSetText CAN encode: "
                    + biggestText(canvas.id) + " chars");
                return;
            }
        }

        byte[] rec = KayaWire.txSetDrawing(canvas.id, 800.0, 600.0,
            ref.ops.size(), 0, ref.ops.toArray());
        System.out.printf("one set_drawing record on the wire: %d bytes%n%n", rec.length);

        int[][] sizes = { { 1, 200, 300 }, { 4, 80, 120 }, { 16, 40, 60 } };
        for (int[] size : sizes) {
            final int copies = size[0];
            int warmup = size[1];
            int reps = size[2];
            int ops = OPS_1X * copies;
            System.out.printf("== %dx the scene: %d ops, %d wire values, "
                + "%d warmup + %d timed frames ==%n",
                copies, ops, ref.ops.size() * copies, warmup, reps);

            KayaApp.Draw prebuilt = new KayaApp.Draw(VIEWBOX);
            emit(prebuilt, 0.3, copies);
            final List<Object> opsList = prebuilt.ops;
            final byte[] record = KayaWire.txSetDrawing(canvas.id, 800.0, 600.0,
                opsList.size(), 0, opsList.toArray());

            double b = bench("build (Draw op list)", warmup, reps, t -> {
                KayaApp.Draw d = new KayaApp.Draw(VIEWBOX);
                emit(d, t, copies);
                sink = d.ops.size();
            }, ops);
            double e = bench("encode (txSetDrawing)", warmup, reps, t -> {
                sink = KayaWire.txSetDrawing(canvas.id, 800.0, 600.0,
                    opsList.size(), 0, opsList.toArray()).length;
            }, ops);
            double s = bench("submit (tx+JNI copy+core decode)", warmup, reps,
                t -> KayaRing.submit(KayaWire.tx(record)), ops);
            double fr = bench("FRAME (build+encode+submit)", warmup, reps, t -> {
                app.build(tx -> {
                    tx.draw(canvas, d -> emit(d, t, copies));
                    return null;
                });
            }, ops);
            System.out.printf("  phases sum %.3f ms vs measured frame %.3f ms%n",
                b + e + s, fr);
            System.out.printf("  JVM heap in use after this size: %d MB%n%n", heapMb());
        }
        System.out.println("NOTE: every submit above queues a decoded transaction in the "
            + "core's channel\n      (no UI thread drains it here).");
    }

    /** How many wire values this binding's encoder actually accepts —
     * measured by bisection rather than computed, so the number is the
     * encoder's and not this file's arithmetic. */
    private static int biggestEncodable(long widget) {
        int lo = 0;
        int hi = 4096;
        while (lo < hi) {
            int mid = (lo + hi + 1) / 2;
            Object[] vals = new Object[mid];
            Arrays.fill(vals, 1.0);
            try {
                KayaWire.txSetDrawing(widget, 800.0, 600.0, mid, 0, vals);
                lo = mid;
            } catch (RuntimeException e) {
                hi = mid - 1;
            }
        }
        return lo;
    }

    /** The same bisection over a plain text prop. */
    private static int biggestText(long widget) {
        int lo = 0;
        int hi = 16384;
        while (lo < hi) {
            int mid = (lo + hi + 1) / 2;
            char[] c = new char[mid];
            Arrays.fill(c, 'x');
            try {
                KayaWire.txSetText(widget, new String(c));
                lo = mid;
            } catch (RuntimeException e) {
                hi = mid - 1;
            }
        }
        return lo;
    }

    static int sink;

    private CanvasMarshalBench() {}
}
