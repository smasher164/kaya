package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The window conformance scene from the JVM — see guests/rust/window.rs
 * for the full rationale. The title must MATERIALIZE (the runner reads
 * the real title bar, never the model's copy), and the advisory size
 * request must be honored on a desktop — 640x400, deliberately off the
 * 540x330 default so an ignored request cannot pass by luck. A desktop
 * scene: phones reject the size by physics, so runners register it on
 * the desktops only (DESIGN.md, Presentation contexts).
 */
final class Window {
    static void app() {
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
