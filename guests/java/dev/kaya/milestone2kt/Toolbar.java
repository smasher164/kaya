package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The toolbar conformance scene, JVM port: the {@code primary} bit as
 * real window chrome (docs/chrome-plan.md C2). The app declares ONE
 * catalog and marks two actions primary; every host promotes the same
 * first two in catalog preorder — the desktop's toolbar, the phones' top
 * bar — and the rest of the catalog stays reachable where that host
 * keeps it.
 *
 * <p>There is no toolbar vocabulary to spell here, and that is the
 * point: this guest is the menus guest with a promotion bit and no new
 * call. Canonical semantics in guests/rust/toolbar.rs; the byte-frozen
 * contract in tools/scenes/toolbar.steps.
 */
final class Toolbar {
    // The guest's own copy of the enablement, flipped by the button. A
    // field rather than a local because a Java lambda cannot assign a
    // captured one; the signal is the model either way.
    private static boolean saveEnabled = true;

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("ready");
            // The one signal the enablement round-trip turns on. The app
            // writes it against the MENU ITEM and says nothing about any
            // button: the promoted button is that same item, so it
            // follows or the lowering kept a copy.
            KayaApp.Signal<Boolean> canSave = tx.signal(true);

            // CATALOG PREORDER DECIDES PROMOTION — top-level groupings
            // in menubar-append order, then each node's children in
            // append order, depth-first. Save is the first primary and
            // Find the second, so every host's promoted set is
            // [Save, Find] however large its own k is.
            KayaApp.WindowRef win = tx.window(0).title("toolbar");
            KayaApp.MenuItem file = win.menu("File");
            // `DONE` is the checkmark idiom: the vocabulary has no
            // save-specific glyph, and neither does Apple's own catalog
            // (docs/styling-plan.md D6).
            file.item("Save")
                    .symbol(KayaApp.Symbol.DONE)
                    .primary(true)
                    .enabled(canSave)
                    .shortcut("primary+s")
                    .onActivate(t -> t.write(status, "saved"));
            file.item("Export")
                    .symbol(KayaApp.Symbol.FORWARD)
                    .onActivate(t -> t.write(status, "exported"));

            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Find")
                    .symbol(KayaApp.Symbol.SEARCH)
                    .primary(true)
                    .onActivate(t -> t.write(status, "found"));
            // The remainder: everything below is catalog, not chrome, on
            // every platform — which is what makes the bare
            // expect_toolbar's second half a real question.
            edit.item("Replace").symbol(KayaApp.Symbol.EDIT);

            KayaApp.MenuItem view = win.menu("View");
            view.item("Refresh").symbol(KayaApp.Symbol.REFRESH);
            view.item("Info").symbol(KayaApp.Symbol.INFO);

            tx.mount(tx.column(() -> {
                tx.label(status); // label#0
                tx.button("toggle save", t -> { // button#0
                    saveEnabled = !saveEnabled;
                    t.write(canSave, saveEnabled);
                });
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Toolbar() {}
}
