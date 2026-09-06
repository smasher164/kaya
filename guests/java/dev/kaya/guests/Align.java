package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The align scene from the JVM — guests/rust/align.rs, tools/scenes/align.steps.
 */
public final class Align {
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

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> probe = tx.signal("align probe");
            KayaApp.Signal<String> base = tx.signal("base");
            KayaApp.Signal<String> anchor = tx.signal("anchor");
            KayaApp.Signal<String> fit = tx.signal("fit");
            KayaApp.Signal<String> plain = tx.signal("plain probe");

            tx.mount(tx.column(() -> {
                tx.column(() -> { // the center trio
                    tx.label(probe); // label#0
                    tx.button("mid");
                    tx.row(() -> { // the baseline trio
                        tx.label(base); // label#1
                        tx.button("tick");
                        tx.image(TALL_PNG);
                    }).align(KayaApp.Align.BASELINE).a11yId("baseline");
                }).align(KayaApp.Align.CENTER).a11yId("centered");
                tx.row(() -> { // row#1: the stretch pair's host
                    tx.label(anchor); // label#2
                    tx.column(() -> {
                        tx.label(fit); // label#3
                        tx.button("wide");
                    }).grow(1.0).align(KayaApp.Align.STRETCH).a11yId("fitcol");
                });
                // row@plain: NO align, so the core's centre default is what
                // the scene reads
                tx.row(() -> {
                    tx.label(plain).a11yId("plainlabel"); // label#4
                    tx.image(TALL_PNG);
                }).a11yId("plain");
            }).align(KayaApp.Align.STRETCH).a11yId("root"));
            return null;
        });

        app.dispatchLoop();
    }

    private Align() {}
}
