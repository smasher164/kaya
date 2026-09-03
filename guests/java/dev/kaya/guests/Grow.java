package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The grow scene from the JVM — guests/rust/grow.rs, tools/scenes/grow.steps.
 */
public final class Grow {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> probe = tx.signal("grow probe");
            KayaApp.Signal<String> one = tx.signal("one");

            tx.mount(tx.column(() -> {
                tx.label(probe).grow(1.0); // label#0
                tx.textarea().grow(2.0); // textarea#0
                tx.row(() -> {
                    tx.label(one).grow(1.0); // label#1
                    tx.button("three").grow(3.0);
                }).grow(1.0).spacing(12.0);
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Grow() {}
}
