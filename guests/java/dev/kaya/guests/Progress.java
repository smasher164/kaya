package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The progress scene from the JVM — guests/rust/progress.rs,
 * tools/scenes/progress.steps.
 */
public final class Progress {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("progress");
            tx.mount(tx.column(() -> {
                tx.progress(0.25); // progress#0
                tx.progressIndeterminate(); // progress#1
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Progress() {}
}
