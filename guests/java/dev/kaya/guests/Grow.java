package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The grow conformance scene from the JVM (KAYA_SELFTEST=grow) — see
 * guests/rust/grow.rs for the rationale. Every child is a grower, so
 * each split is exactly weight/Σweight: 1,2,1 divide the column
 * 25/50/25 and the row's 1,3 divide its width 25/75.
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
