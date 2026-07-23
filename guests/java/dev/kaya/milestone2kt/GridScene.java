package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The grid conformance scene from the JVM. See
 * guests/rust/grid.rs and tools/scenes/grid.steps.
 */
final class GridScene {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("grid");
            tx.mount(tx.column(() -> {
                tx.grid(2, () -> {
                    tx.label("Name:"); // label#0
                    tx.label("Ada Lovelace"); // label#1
                    tx.label("Role:"); // label#2
                    tx.label("Engine programmer"); // label#3
                });
                tx.row(() -> {
                    tx.button("left"); // button#0
                    tx.spacer();
                    tx.button("right"); // button#1
                }).grow(1.0);
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private GridScene() {}
}
