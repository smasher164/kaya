package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The menus conformance scene, JVM port: the command vocabulary (a
 * File/View/Sort menu bar, context menus on a live label and on stamped
 * rows), the uncontrolled-menu echo doctrine, and a late
 * rename/append/promotion rework. Canonical semantics in
 * guests/rust/menus.rs; the byte-frozen contract in tools/scenes/menus.steps.
 */
public final class Menus {
    // Java lambdas cannot assign captured locals; these live here for the
    // seed and the Remove fold.
    private static KayaApp.Collection groups;
    private static KayaApp.Collection items;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("ready");
            KayaApp.Signal<Boolean> canExport = tx.signal(false);
            KayaApp.Signal<Boolean> details = tx.signal(false);
            KayaApp.Signal<Double> sort = tx.signal(0.0);

            java.util.function.Consumer<KayaApp.Tx> onShare =
                    t -> t.write(status, "shared");

            KayaApp.WindowRef win = tx.window(0).title("menus");
            KayaApp.MenuItem file = win.menu("File").enabled(canExport);
            // Symbols are CONCEPTS, drawn per platform: the vocabulary
            // has no `save`, so `DONE` is the checkmark idiom
            // (docs/styling-plan.md D6).
            file.item("Save")
                    .symbol(KayaApp.Symbol.DONE)
                    .shortcut("primary+s")
                    .onActivate(t -> t.write(status, "saved"));
            file.item("Export").enabled(canExport).symbol(KayaApp.Symbol.FORWARD);
            KayaApp.MenuItem share = file.item("Share").primary(true).onActivate(onShare);

            win.menu("View").toggle("Details").checked(details)
                    .symbol(KayaApp.Symbol.INFO)
                    .onToggle((t, on) ->
                            t.write(status, on ? "details on" : "details off"));

            // Option order IS the index vocabulary: Name = 0, Date = 1.
            KayaApp.MenuItem sortGroup = win.radioGroup("Sort");
            sortGroup.option("Name");
            sortGroup.option("Date");
            sortGroup.value(sort).onSelect((t, index) ->
                    t.write(status, index == 1 ? "sorted date" : "sorted name"));

            groups = tx.collection();
            KayaApp.ContextCatalog catalog = tx.contextCatalog();
            catalog.item("Remove").symbol(KayaApp.Symbol.DELETE)
                    .onActivateNode((t, keys) -> {
                        String group = (String) keys.get(0);
                        String item = (String) keys.get(1);
                        t.remove(items.at(group), item);
                        t.write(status, "removed " + group + "/" + item);
                    });

            tx.mount(tx.column(() -> {
                tx.label(status); // label#0
                tx.button("enable export", t -> // button#0
                        t.write(canExport, true));
                tx.button("reset menu state", t -> { // button#1
                                        // The folds never echo the user's pick, so these
                                        // writes are real records (never coalesced) that
                                        // reset the backend's user-state mirror.
                    t.write(details, false);
                    t.write(sort, 0.0);
                    t.write(status, "ready");
                });
                tx.button("extend menus", t -> { // button#2
                    // Append-only: rename the retained File, move the
                    // promotion hint, grow the bar by Tools.
                    t.menu(share).primary(false);
                    t.menu(file).label("Document")
                            .item("Publish").primary(true)
                            .symbol(KayaApp.Symbol.COPY)
                            .onActivate(onShare);
                    t.window(0).menu("Tools").item("Inspect")
                            .symbol(KayaApp.Symbol.SEARCH);
                });

                KayaApp.Signal<String> targetText = tx.signal("rename target");
                KayaApp.Widget target = tx.label(targetText); // label#1
                tx.contextMenu(target).item("Rename")
                        .symbol(KayaApp.Symbol.EDIT)
                        .onActivate(t -> t.write(status, "renamed"));

                for (var g : tx.rows(groups)) {
                    g.column(() -> {
                        items = g.collection();
                        for (var row : g.rows(items)) {
                            // label#2 once g2/a stamps
                            row.contextMenu(row.label(row.value()), catalog);
                        }
                    });
                }
            }));
            return null;
        });

        // Seed after mount: the stamp path attaches the shared catalog and keys.
        app.build(tx -> {
            tx.insert(groups, "g2", "Home");
            tx.insert(items.at("g2"), "a", "water plants");
            return null;
        });

        app.dispatchLoop();
    }

    private Menus() {}
}
