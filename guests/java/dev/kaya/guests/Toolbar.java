package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The toolbar scene from the JVM — guests/rust/toolbar.rs,
 * tools/scenes/toolbar.steps.
 */
public final class Toolbar {
    private static boolean saveEnabled = true;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("ready");
            // Written against the MENU ITEM: the promoted button IS that item.
            KayaApp.Signal<Boolean> canSave = tx.signal(true);

            // CATALOG PREORDER DECIDES PROMOTION — menubar-append order, then
            // children depth-first, so every host promotes [Save, Find].
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
