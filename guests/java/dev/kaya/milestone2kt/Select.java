package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The select conformance scene from the JVM. See
 * guests/rust/select.rs and tools/scenes/select.steps.
 */
final class Select {
    private static final String[] OPTIONS = {"Red", "Green", "Blue"};

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("select");
            KayaApp.Signal<String> picked = tx.signal("picked: Red");

            tx.mount(tx.column(() -> {
                tx.select(OPTIONS, 0, (t, index) ->
                        t.write(picked, "picked: " + OPTIONS[index]));
                tx.label(picked); // label#0
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Select() {}
}
