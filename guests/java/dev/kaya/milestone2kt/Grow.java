package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The grow conformance scene from the JVM — see guests/rust/grow.rs
 * for the full rationale. Every child of the column and of the row is
 * a grower, so each split is exactly weight/Σweight: 1,2,1 divide the
 * column 25/50/25 and the row's 1,3 divide its width 25/75. The
 * harness (KAYA_SELFTEST=grow) asserts both splits, root-fills, and
 * that the textarea TAKES the track its weight earned, byte-for-byte
 * against every other language and backend.
 *
 * The grow chain at construction is Java's declarative spelling;
 * Tx.setGrow is the dynamic path this scene has no reason to use.
 */
final class Grow {
    static void app() {
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
