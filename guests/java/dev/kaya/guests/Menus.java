package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The menus scene from the JVM — guests/rust/menus.rs, tools/scenes/menus.steps.
 */
public final class Menus {
    // Java lambdas cannot assign captured locals.
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
            // No `save` in the symbol vocabulary; DONE is the checkmark idiom
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
                    t.write(details, false);
                    t.write(sort, 0.0);
                    t.write(status, "ready");
                });
                tx.button("extend menus", t -> { // button#2
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

        // Seeded after the mount, so the copy stamps from a closed template.
        app.build(tx -> {
            tx.insert(groups, "g2", "Home");
            tx.insert(items.at("g2"), "a", "water plants");
            return null;
        });

        app.dispatchLoop();
    }

    private Menus() {}
}
