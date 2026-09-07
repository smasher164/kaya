package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * The search scene from the JVM — guests/rust/search.rs,
 * tools/scenes/search.steps. The app owns the filter
 * (docs/search-plan.md S9): the visible set is a diff of removes and
 * inserts by key.
 */
public final class Search {
    @KayaGen(key = "String")
    record SearchItem(String name) {}

    private static final String[] NAMES = { "apple", "banana", "cherry", "mango" };

    public static void app() {
        KayaApp app = new KayaApp();
        List<String> visible = new ArrayList<>(List.of(NAMES));

        app.build(tx -> {
            var items = SearchItemKaya.collection(tx);
            KayaApp.Signal<String> count = tx.signal(NAMES.length + " items");

            tx.mount(tx.column(() -> {
                tx.search((t, text) -> {
                    String query = text.toLowerCase(Locale.ROOT);
                    List<String> wanted = new ArrayList<>();
                    for (String name : NAMES) {
                        if (name.contains(query)) {
                            wanted.add(name);
                        }
                    }
                    // A DIFF, never clear-and-refill: only the rows whose
                    // membership changed move (docs/search-plan.md S9).
                    for (String name : visible) {
                        if (!wanted.contains(name)) {
                            t.remove(items.handle, name);
                        }
                    }
                    for (String name : wanted) {
                        if (!visible.contains(name)) {
                            items.insert(t, name, new SearchItem(name));
                        }
                    }
                    // Insertion order is arrival order, so a row coming back
                    // lands last; walking the wanted keys to the end in
                    // order puts the list back in NAMES order.
                    for (String name : wanted) {
                        items.moveToEnd(t, name);
                    }
                    t.write(count, query.isEmpty()
                            ? NAMES.length + " items"
                            : wanted.size() + " of " + NAMES.length + " match");
                    visible.clear();
                    visible.addAll(wanted);
                }).placeholder("Search").a11yId("find").a11yLabel("Find items");
                tx.label(count).a11yId("count");
                // The For IS the list: expect_order reads its label children.
                var rows = SearchItemKaya.rows(tx, items);
                for (var row : rows) {
                    row.label(row.name);
                }
                tx.setA11yId(rows.handle, "list");
            }));

            for (String name : NAMES) {
                items.insert(tx, name, new SearchItem(name));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private Search() {}
}
