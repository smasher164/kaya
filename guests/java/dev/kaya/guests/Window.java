package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The window scene from the JVM — guests/rust/window.rs,
 * tools/scenes/window.steps.
 */
public final class Window {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("window probe").size(640.0, 400.0);
            KayaApp.Signal<String> probe = tx.signal("window probe");
            tx.mount(tx.column(() -> {
                tx.label(probe); // label#0
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Window() {}
}
