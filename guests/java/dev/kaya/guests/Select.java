package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The select scene from the JVM — guests/rust/select.rs,
 * tools/scenes/select.steps.
 */
public final class Select {
    private static final String[] OPTIONS = {"Red", "Green", "Blue"};

    public static void app() {
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
