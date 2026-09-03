package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The window conformance scene from the JVM — see guests/rust/window.rs
 * for the rationale. 640x400 is deliberately off the 540x330 default so
 * an ignored size request cannot pass by luck. DESKTOP ONLY: phones
 * reject the size by physics.
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
