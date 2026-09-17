package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The layout scene from the JVM — guests/rust/layout.rs,
 * tools/scenes/layout.steps.
 */
public final class Layout {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> probe = tx.signal("Layout probe");
            KayaApp.Signal<String> tail = tx.signal("tail");
            KayaApp.Signal<String> mixed = tx.signal("mixed");
            KayaApp.Signal<String> nested = tx.signal("nested");
            KayaApp.Signal<String> deep = tx.signal("deep");

            tx.mount(tx.column(col -> {
                tx.label(probe); // label#0

                tx.row(row -> {
                    tx.button("A");
                    tx.button("longer");
                    tx.label(tail); // label#1
                });

                tx.row(row2 -> {
                    tx.checkbox("check", null);
                    tx.label(mixed); // label#2
                    tx.slider(0.0, 1.0, 0.5, null).grow(1.0);
                });

                tx.row(row3 -> {
                    tx.slider(0.0, 1.0, 0.25, null).grow(1.0);
                    tx.slider(0.0, 1.0, 0.75, null).grow(3.0);
                });

                tx.column(col2 -> {
                    tx.label(nested); // label#3
                    tx.row(row4 -> {
                        tx.label(deep); // label#4
                        tx.button("x");
                    });
                });
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Layout() {}
}
