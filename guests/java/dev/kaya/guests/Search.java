package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

import java.util.Locale;

/**
 * The search scene from the JVM — guests/rust/search.rs,
 * tools/scenes/search.steps. The app owns the predicate
 * (docs/search-plan.md S9) and each row hides in place
 * (docs/hidden-plan.md).
 */
public final class Search {
    @KayaGen(key = "String")
    record SearchItem(String name, boolean unmatched) {}

    private static final String[] NAMES = { "apple", "banana", "cherry", "mango" };

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("search");
            var items = SearchItemKaya.collection(tx);
            KayaApp.Signal<String> count = tx.signal(NAMES.length + " items");

            tx.mount(tx.column(col -> {
                tx.search((t, text) -> {
                    String query = text.toLowerCase(Locale.ROOT);
                    int wanted = 0;
                    for (String name : NAMES) {
                        SearchItemKaya.patch(t, items, name).unmatched(!name.contains(query));
                        if (name.contains(query)) {
                            wanted++;
                        }
                    }
                    t.write(count, query.isEmpty()
                            ? NAMES.length + " items"
                            : wanted + " of " + NAMES.length + " match");
                }).placeholder("Search").a11yId("find").a11yLabel("Find items");
                tx.label(count).a11yId("count");
                // The For IS the list: expect_order reads its label children.
                var rows = SearchItemKaya.rows(tx, items);
                for (var row : rows) {
                    row.setHidden(row.label(row.name), row.unmatched);
                }
                tx.setA11yId(rows.handle, "list");
            }));

            for (String name : NAMES) {
                items.insert(tx, name, new SearchItem(name, false));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private Search() {}
}
