package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The scroll conformance scene from the JVM — the viewport grows so
 * the enclosing track constrains it (an unconstrained viewport hugs
 * its content and nothing overflows); the bottom button, reachable
 * only by scrolling, proves the scrolled-to content is live. See
 * guests/rust/scroll.rs and tools/scenes/scroll.steps.
 */
final class Scroll {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.windowTitle("scroll");
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
