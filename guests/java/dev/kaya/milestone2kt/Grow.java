package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The grow conformance scene from the JVM — see guests/rust/grow.rs
 * for the full rationale. Every child of the column and of the row is
 * a grower, so each split is exactly weight/Σweight: 1,1,2 divide the
 * column 25/25/50 and the row's 1,3 divide its width 25/75. The
 * harness (KAYA_SELFTEST=grow) asserts both splits plus root-fills,
 * byte-for-byte against every other language and backend.
 *
 * setGrow directly after construction is Java's spelling — the
 * language has no named or optional arguments.
 */
final class Grow {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> probe = tx.signal("grow probe");
            KayaApp.Signal<String> one = tx.signal("one");

            tx.mount(tx.column(() -> {
                KayaApp.Widget label = tx.label(probe); // label#0
                tx.setGrow(label, 1.0);
                KayaApp.Widget quarter = tx.button("quarter");
                tx.setGrow(quarter, 1.0);
                KayaApp.Widget band = tx.row(() -> {
                    KayaApp.Widget tick = tx.label(one); // label#1
                    tx.setGrow(tick, 1.0);
                    KayaApp.Widget three = tx.button("three");
                    tx.setGrow(three, 3.0);
                });
                tx.setGrow(band, 2.0);
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Grow() {}
}
