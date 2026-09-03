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
            tx.mount(tx.column(() -> {
                tx.label(status); // label#0
                tx.scroll(() -> { // scroll#0
                    tx.column(() -> {
                        for (int i = 1; i <= 29; i++) {
                            KayaApp.Signal<String> caption = tx.signal("row " + i);
                            tx.label(caption);
                        }
                        tx.button("bottom", inner -> // button#0
                                inner.write(status, "bottom clicked"));
                    });
                }).grow(1);
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Scroll() {}
}
