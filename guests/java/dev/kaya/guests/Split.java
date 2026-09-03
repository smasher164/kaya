package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The split conformance scene from the JVM — adaptive panes via the
 * chain spelling. The guest asks for the presentation ONCE and does
 * nothing adaptive after that; the platform re-decides as the size
 * class changes.
 *
 * <p>TWO scripts drive this ONE app: split resizes and names the
 * presentation on each side, listdetail asserts the bare invariant at
 * whatever width its host gives. See guests/rust/split.rs,
 * tools/scenes/split.steps and tools/scenes/listdetail.steps.
 */
public final class Split {
    private static final long DETAIL = 7;

    public static void app() {
        KayaApp app = new KayaApp();

        KayaApp.Signal<String> status = app.build(tx -> {
            tx.window(0).title("split").panes(2);
            KayaApp.Signal<String> s = tx.signal("list pane");
            tx.mount(tx.column(() -> {
                // Authored ids so the read goes through the REAL tree:
                // an index read passes whether or not anything reached
                // the screen, which once let a non-rendering split arm
                // look green.
                tx.label(s).a11yId("list"); // label#0
                tx.button("open detail", inner -> { // button#0
                    long entry = inner.pushEntry(DETAIL)
                            .title("detail")
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

        if (status == null) throw new IllegalStateException();

        app.dispatchLoop();
    }

    private Split() {}
}
