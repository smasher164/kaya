package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The panes scene from the JVM — guests/rust/panes.rs, tools/scenes/panes.steps.
 */
public final class Panes {
    private static final long CONTENT = 7;
    private static final long DETAIL = 8;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("panes").panes(3);
            KayaApp.Signal<String> root = tx.signal("root pane");
            tx.mount(tx.column(() -> {
                tx.label(root).a11yId("root"); // label#0
                tx.button("open content", inner -> { // button#0
                    long entry = inner.pushEntry(CONTENT).title("content").id();
                    KayaApp.Widget pane = inner.column(() -> {
                        KayaApp.Signal<String> caption = inner.signal("content pane");
                        inner.label(caption).a11yId("content"); // label#1
                        inner.button("open detail", deep -> { // button#1
                            long leaf = deep.pushEntry(DETAIL).title("detail").id();
                            KayaApp.Widget detail = deep.column(() -> {
                                KayaApp.Signal<String> tail = deep.signal("detail pane");
                                deep.label(tail).a11yId("detail"); // label#last
                            });
                            deep.mountIn(leaf, detail);
                        });
                    });
                    inner.mountIn(entry, pane);
                });
            }));
        });

        app.dispatchLoop();
    }

    private Panes() {}
}
