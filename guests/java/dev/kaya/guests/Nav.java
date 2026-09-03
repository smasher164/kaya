package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The nav conformance scene from the JVM — the serial navigation
 * grammar via the chain spelling. See guests/rust/nav.rs and
 * tools/scenes/nav.steps.
 *
 * <p>Two behaviours the scene asserts: a covered root is RETAINED and
 * keeps taking writes, and a programmatic popEntry does NOT echo
 * entry_popped.
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
                    // The veto class: nothing has popped when the
                    // handler runs, so it agrees and confirms.
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
