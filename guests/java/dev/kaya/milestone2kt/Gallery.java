package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The gallery scene from the JVM: a row with a checkbox and its status
 * label, and a row with a slider and its volume label. Both controls
 * own their state and report each change; the app answers by writing
 * the paired signal — the entry's uncontrolled contract, with a bool
 * and a double.
 */
final class Gallery {
    static void app() {
        KayaApp app = new KayaApp();

        // The construction sugar: constructors carry their handlers,
        // containers take their children, and the build body reads as
        // the tree.
        app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("urgent: false");
            KayaApp.Signal<String> volume = tx.signal("volume: 50%");

            tx.mount(tx.column(
                    tx.row(
                            tx.checkbox("urgent", (t, checked) ->
                                    t.write(status, "urgent: " + checked)),
                            tx.label(status)),
                    tx.row(
                            // Integer percent, so every language's
                            // formatting agrees.
                            tx.slider(0.0, 1.0, 0.5, (t, value) ->
                                    t.write(volume, "volume: " + Math.round(value * 100) + "%")),
                            tx.label(volume))));
            return null;
        });

        app.dispatchLoop();
    }

    private Gallery() {}
}
