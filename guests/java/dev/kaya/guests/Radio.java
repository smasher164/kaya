package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The radio scene from the JVM — guests/rust/radio.rs, tools/scenes/radio.steps.
 */
public final class Radio {
    private static final String[] OPTIONS = {"Small", "Medium", "Large"};

    public static void app() {
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
