package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The nav conformance scene from the JVM — the serial navigation
 * grammar via the chain spelling: pushEntry chains props, mountIn
 * presents the entry's root, onEntryPopped hears the user's native
 * pop, and onBackRequested answers the intercept_back veto with
 * popEntry. The covered root is RETAINED (status keeps taking writes
 * while covered); a programmatic popEntry does not echo
 * entry_popped, so the settings round's final status stays "back
 * requested". See guests/rust/nav.rs and tools/scenes/nav.steps.
 */
final class Nav {
    private static final long DETAIL = 7;
    private static final long SETTINGS = 8;

    static void app() {
        KayaApp app = new KayaApp();

        KayaApp.Signal<String> status = app.build(tx -> {
            tx.window(0).title("nav");
            KayaApp.Signal<String> s = tx.signal("at root");
            tx.mount(tx.column(() -> {
                tx.label(s); // label#0
                tx.button("open detail", inner -> { // button#0
                    // The popped handler rides the push (per-entry,
                    // the onResult precedent): it can only ever mean
                    // the detail screen popped, and it retires with
                    // the one pop.
                    long entry = inner.pushEntry(DETAIL)
                            .title("detail")
                            .onPopped(tx2 -> tx2.write(s, "popped detail"))
                            .id();
                    KayaApp.Widget pane = inner.column(() -> {
                        KayaApp.Signal<String> caption = inner.signal("detail pane");
                        inner.label(caption);
                    });
                    inner.mountIn(entry, pane);
                    // The covered root keeps taking writes —
                    // retention, observable after the pop.
                    inner.write(s, "pushed detail");
                });
                tx.button("open settings", inner -> { // button#1
                    // The veto class: nothing has popped; agree and
                    // confirm. No entry_popped will fire — the write
                    // is the round's final status.
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

        // status is captured by the handlers above; keep the local
        // alive for symmetry with the other scenes.
        if (status == null) throw new IllegalStateException();

        app.dispatchLoop();
    }

    private Nav() {}
}
