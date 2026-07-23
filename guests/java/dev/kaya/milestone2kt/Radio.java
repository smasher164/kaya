package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The radio conformance scene from the JVM. See
 * guests/rust/radio.rs and tools/scenes/radio.steps.
 */
final class Radio {
    private static final String[] OPTIONS = {"Small", "Medium", "Large"};

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("radio");
            KayaApp.Signal<String> size = tx.signal("size: Small");

            tx.mount(tx.column(() -> {
                tx.radio(OPTIONS, 0, (t, index) ->
                        t.write(size, "size: " + OPTIONS[index]));
                tx.label(size); // label#0
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Radio() {}
}
