package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The sizepolicy scene from the JVM — guests/rust/sizepolicy.rs,
 * tools/scenes/sizepolicy.steps.
 */
public final class SizePolicy {
    /** The declared box of the two CONSTANT-mode canvases: the one number
     * {@code scale} and {@code fixed} disagree about. */
    private static final KayaApp.Viewbox BOX = new KayaApp.Viewbox(300.0, 120.0);

    /** A rectangle at l..r and t..b as FRACTIONS of the box. */
    private static void panel(KayaApp.Draw d, KayaApp.Viewbox box,
            double l, double t, double r, double b, KayaApp.Paint paint) {
        double w = box.w();
        double h = box.h();
        d.moveTo(l * w, t * h)
            .lineTo(r * w, t * h)
            .lineTo(r * w, b * h)
            .lineTo(l * w, b * h)
            .close()
            .fill(paint, KayaApp.FillRule.NONZERO);
    }

    /** The figure the three drawing canvases share. The centre probe point is
     * opaque, which is what expect_ink rests on. */
    private static void figure(KayaApp.Draw d, KayaApp.Viewbox box) {
        panel(d, box, 0.05, 0.0, 0.95, 1.0, KayaApp.Paint.GROUND);
        panel(d, box, 0.25, 0.0, 0.75, 1.0, KayaApp.Paint.SERIES_FILL);
    }

    /** The bar whose RIGHT EDGE is the frame number; the scene asserts exact
     * frames. */
    private static void bar(KayaApp.Draw d, KayaApp.Viewbox box, long frame) {
        panel(d, box, 0.25, 0.0, 0.35 + 0.10 * frame, 1.0, KayaApp.Paint.AXIS);
    }

    /** Seconds back to the frame the harness drove, off the time the guest was
     * HANDED and never a clock of its own (docs/canvas-plan.md §15.4). */
    private static long frameOf(double time) {
        return Math.max(0L, Math.round(time * 60.0));
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("sizepolicy").size(480.0, 420.0);

            tx.mount(tx.column(() -> {
                // SCALE (the default)
                KayaApp.Widget fit = tx.canvas(BOX).grow(1.0)
                        .a11yId("fit").a11yLabel("Scaled panel");
                tx.draw(fit, d -> figure(d, BOX));

                // FIXED
                KayaApp.Widget mark = tx.canvas(BOX).grow(1.0).fixed()
                        .a11yId("mark").a11yLabel("Fixed mark");
                tx.draw(mark, d -> figure(d, BOX));

                // REDRAW
                tx.canvas(BOX).grow(1.0)
                        .a11yId("live").a11yLabel("Redrawn panel")
                        .onDraw((d, size) -> figure(d, size));

                // TICK: under the harness the clock is the core's own step.
                tx.canvas(BOX).grow(1.0)
                        .a11yId("clock").a11yLabel("Animated bar")
                        .onTick((d, size, time) -> bar(d, size, frameOf(time)));
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private SizePolicy() {}
}
