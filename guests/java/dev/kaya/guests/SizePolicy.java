package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The canvas SIZE-POLICY scene from the JVM (KAYA_SELFTEST=sizepolicy) —
 * see guests/rust/sizepolicy.rs for the rationale, and
 * tools/scenes/sizepolicy.steps for the byte-frozen contract.
 *
 * <p>ALL FOUR CANVASES GROW, which is the only reason the scene can see
 * anything: an ungrown canvas is its natural size, so its track IS its
 * viewbox and every policy agrees.
 *
 * <p>EVERY FIGURE IS DRAWN IN FRACTIONS OF THE BOX IT IS HANDED, which
 * is why one frozen expectation serves four different tracks.
 */
public final class SizePolicy {
    /** The declared box of the two CONSTANT-mode canvases: a {@code
     * scale} canvas keeps drawing in it at any size and a {@code fixed}
     * one refuses to leave it, so it is the one number they disagree
     * about. */
    private static final KayaApp.Viewbox BOX = new KayaApp.Viewbox(300.0, 120.0);

    /** An axis-aligned rectangle at l..r and t..b as FRACTIONS of the
     * box, filled with one paint role. */
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

    /** The figure the three drawing canvases share. The centre probe
     * point is opaque — the ground is opaque and the series fill blends
     * onto it — which is what expect_ink rests on. */
    private static void figure(KayaApp.Draw d, KayaApp.Viewbox box) {
        panel(d, box, 0.05, 0.0, 0.95, 1.0, KayaApp.Paint.GROUND);
        panel(d, box, 0.25, 0.0, 0.75, 1.0, KayaApp.Paint.SERIES_FILL);
    }

    /** The animating canvas's bar, whose RIGHT EDGE is the frame number:
     * 35 hundredths plus ten per frame. The scene asserts exact frames,
     * so a clock that free-ran would put the edge somewhere else. */
    private static void bar(KayaApp.Draw d, KayaApp.Viewbox box, long frame) {
        panel(d, box, 0.25, 0.0, 0.35 + 0.10 * frame, 1.0, KayaApp.Paint.AXIS);
    }

    /** Seconds back to the frame the harness drove. The clock is the
     * core's HARNESS_FRAME_HZ; the guest reads the time it was HANDED
     * and never one of its own (docs/canvas-plan.md §15.4). */
    private static long frameOf(double time) {
        return Math.max(0L, Math.round(time * 60.0));
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("sizepolicy").size(480.0, 420.0);

            tx.mount(tx.column(() -> {
                // SCALE, the default: nothing is declared, and the core
                // re-rasterizes this same display list at whatever track
                // the column hands over, fitted uniformly and centred.
                KayaApp.Widget fit = tx.canvas(BOX).grow(1.0)
                        .a11yId("fit").a11yLabel("Scaled panel");
                tx.draw(fit, d -> figure(d, BOX));

                // FIXED: the one true property. This one draws at BOX
                // whatever the column does with it, and the backend blits
                // it 1:1 with the leftover as margin.
                KayaApp.Widget mark = tx.canvas(BOX).grow(1.0).fixed()
                        .a11yId("mark").a11yLabel("Fixed mark");
                tx.draw(mark, d -> figure(d, BOX));

                // REDRAW: the drawing IS a function of size, and saying
                // so is providing the function. The viewbox declared here
                // is only the size before the first answer.
                tx.canvas(BOX).grow(1.0)
                        .a11yId("live").a11yLabel("Redrawn panel")
                        .onDraw((d, size) -> figure(d, size));

                // TICK: the same, once a frame, at the time the platform
                // supplied. Under the harness that clock is the core's
                // own step and a verb advances it.
                tx.canvas(BOX).grow(1.0)
                        .a11yId("clock").a11yLabel("Animated bar")
                        .onTick((d, size, time) -> bar(d, size, frameOf(time)));
            }));
            return null;
        });

        // Every occurrence this scene has is a canvas ask, and the
        // binding answers those inside the loop — this is what keeps the
        // app thread alive to hold the scene up.
        app.dispatchLoop();
    }

    private SizePolicy() {}
}
