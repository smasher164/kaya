package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The nav scene from the JVM — guests/rust/nav.rs, tools/scenes/nav.steps.
 */
public final class Nav {
    private static final long DETAIL = 7;
    private static final long SETTINGS = 8;

    public static void app() {
        KayaApp app = new KayaApp();

        KayaApp.Signal<String> status = app.build(tx -> {
            tx.window(0).title("nav");
            KayaApp.Signal<String> s = tx.signal("at root");
            tx.mount(tx.column(() -> {
                tx.label(s); // label#0
                tx.button("open detail", inner -> { // button#0
                    long entry = inner.pushEntry(DETAIL)
                            .title("detail")
                            .onPopped(tx2 -> tx2.write(s, "popped detail"))
                            .id();
                    KayaApp.Widget pane = inner.column(() -> {
                        KayaApp.Signal<String> caption = inner.signal("detail pane");
                        inner.label(caption);
                    });
                    inner.mountIn(entry, pane);
                    inner.write(s, "pushed detail");
                });
                tx.button("open settings", inner -> { // button#1
                    // Nothing has popped when the handler runs, so it confirms.
                    long entry = inner.pushEntry(SETTINGS)
                            .title("settings")
                            .interceptBack(true)
                            .onBackRequested(tx2 -> {
                                tx2.write(s, "back requested");
                                tx2.popEntry();
                            })
                            .id();
                    KayaApp.Widget pane = inner.column(() -> {
                        KayaApp.Signal<String> caption = inner.signal("settings pane");
                        inner.label(caption);
                    });
                    inner.mountIn(entry, pane);
                    inner.write(s, "pushed settings");
                });
            }));
            return s;
        });

        if (status == null) throw new IllegalStateException();

        app.dispatchLoop();
    }

    private Nav() {}
}
