package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The toolbar conformance scene, JVM port: the {@code primary} bit as
 * real window chrome (docs/chrome-plan.md C2). One catalog, two actions
 * marked primary, and every host promotes the same first two. Canonical
 * semantics in guests/rust/toolbar.rs; the byte-frozen contract in
 * tools/scenes/toolbar.steps.
 */
public final class Toolbar {
    private static boolean saveEnabled = true;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("ready");
            // Written against the MENU ITEM and nothing else: the
            // promoted button is that same item, so it follows or the
            // lowering kept a copy.
            KayaApp.Signal<Boolean> canSave = tx.signal(true);

            // CATALOG PREORDER DECIDES PROMOTION — groupings in
            // menubar-append order, then children depth-first. Save is
            // the first primary and Find the second, so every host's
            // promoted set is [Save, Find] whatever its own k is.
            KayaApp.WindowRef win = tx.window(0).title("toolbar");
            KayaApp.MenuItem file = win.menu("File");
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
