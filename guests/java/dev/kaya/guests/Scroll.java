package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The scroll scene from the JVM — guests/rust/scroll.rs,
 * tools/scenes/scroll.steps.
 */
public final class Scroll {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("scroll");
            KayaApp.Signal<String> status = tx.signal("at top");
            tx.mount(tx.column(col -> {
                tx.label(status); // label#0
                tx.scroll(scrollBox -> { // scroll#0
                    tx.column(col2 -> {
                        for (int i = 1; i <= 29; i++) {
                            KayaApp.Signal<String> caption = tx.signal("row " + i);
                            tx.label(caption);
                        }
                        tx.button("bottom", inner -> // button#0
                                inner.write(status, "bottom clicked"));
                    });
                }).grow(1).a11yId("rows");
                // A strip wider than the window, scrolled sideways
                // (docs/hscroll-plan.md), addressed as scroll@strip.
                tx.scroll(strip -> {
                    tx.row(cards -> {
                        for (int i = 1; i <= 19; i++) {
                            KayaApp.Signal<String> caption = tx.signal("card " + i);
                            tx.label(caption);
                        }
                        tx.button("last card", inner ->
                                inner.write(status, "last card clicked")).a11yId("last");
                    });
                }).axis(KayaApp.Axis.HORIZONTAL).a11yId("strip");
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Scroll() {}
}
