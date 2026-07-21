package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The align conformance scene from the JVM — see guests/rust/align.rs
 * and tools/scenes/align.steps for the full rationale. The root
 * column centers children of three different natural widths; the row
 * aligns baselines across a label, a checkbox, and a tall no-baseline
 * image whose bottom sits ON the baseline (the CSS replaced-element
 * rule) — the construction that separates the modes on every
 * platform's control metrics.
 */
final class Align {
    // A 2x64 PNG: the tall no-baseline child.
    private static final byte[] TALL_PNG = {
        -119, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13,
        73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 64,
        8, 2, 0, 0, 0, -65, 68, 49, 20, 0, 0, 0,
        18, 73, 68, 65, 84, 120, -100, 99, 8, 8, -118, 2,
        34, -122, 81, 106, 104, 82, 0, 67, 50, 126, 1, 49,
        1, 65, 124, 0, 0, 0, 0, 73, 69, 78, 68, -82,
        66, 96, -126,
    };

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> probe = tx.signal("align probe");
            KayaApp.Signal<String> base = tx.signal("base");

            tx.mount(tx.column(() -> {
                tx.label(probe); // label#0
                tx.button("mid");
                tx.row(() -> {
                    tx.label(base); // label#1
                    tx.button("tick");
                    tx.image(TALL_PNG);
                }).align(KayaApp.Align.BASELINE);
            }).align(KayaApp.Align.CENTER));
            return null;
        });

        app.dispatchLoop();
    }

    private Align() {}
}
