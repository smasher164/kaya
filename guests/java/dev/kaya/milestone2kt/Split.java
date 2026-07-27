package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The split conformance scene from the JVM — adaptive list-detail via
 * the chain spelling: listDetail rides the window chain, pushEntry
 * chains the entry's props, mountIn presents its root, and onPopped
 * hears the user's native pop.
 *
 * <p>The guest asks for the presentation ONCE and then does nothing
 * adaptive ever again. Everything after that is the platform
 * re-deciding as the size class changes: an app does not write two
 * layouts and pick one, and there is no prop for WHICH way it
 * presents. Nothing here is split-specific except that one prop.
 *
 * <p>TWO scripts drive this ONE app: split resizes and names the
 * presentation on each side, listdetail asserts the bare invariant at
 * whatever width its host gives. See guests/rust/split.rs,
 * tools/scenes/split.steps and tools/scenes/listdetail.steps.
 */
final class Split {
    private static final long DETAIL = 7;

    static void app() {
        KayaApp app = new KayaApp();

        KayaApp.Signal<String> status = app.build(tx -> {
            // The one adaptive declaration in the whole guest.
            tx.window(0).title("split").listDetail(true);
            KayaApp.Signal<String> s = tx.signal("list pane");
            tx.mount(tx.column(() -> {
                // Authored ids so the REAL-TREE read can address
                // these: an index read passes whether or not anything
                // reached the screen, which is the gap that let a
                // non-rendering split arm look green.
                tx.label(s).a11yId("list"); // label#0
                tx.button("open detail", inner -> { // button#0
                    // The popped handler rides the push, per-entry —
                    // the onResult precedent, unchanged by the split.
                    long entry = inner.pushEntry(DETAIL)
                            .title("detail")
                            // Retention: the base root took this write
                            // while the detail was up, on a regular
                            // window where it was VISIBLE the whole
                            // time.
                            .onPopped(tx2 -> tx2.write(s, "popped detail"))
                            .id();
                    KayaApp.Widget pane = inner.column(() -> {
                        KayaApp.Signal<String> caption = inner.signal("detail pane");
                        inner.label(caption).a11yId("detail");
                    });
                    inner.mountIn(entry, pane);
                });
            }));
            return s;
        });

        // status is captured by the handlers above; keep the local
        // alive for symmetry with the other scenes.
        if (status == null) throw new IllegalStateException();

        app.dispatchLoop();
    }

    private Split() {}
}
