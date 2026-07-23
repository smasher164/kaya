package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The progress conformance scene from the JVM. See
 * guests/rust/progress.rs and tools/scenes/progress.steps.
 */
final class Progress {
    static void app() {
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
