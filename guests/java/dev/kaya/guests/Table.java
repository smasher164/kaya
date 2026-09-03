package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

import java.util.Comparator;
import java.util.List;

/**
 * The table scene from the JVM — guests/rust/table.rs, tools/scenes/table.steps.
 */
public final class Table {
    @KayaGen(key = "String")
    record TableItem(String name, String size) {}

    // The guest's sort policy; the platform never has one.
    private static long sortedCol = -1;
    private static boolean sortedDesc;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var items = TableItemKaya.collection(tx);
            // The root is a row so the For's container is the scene's only
            // column-kind widget (the reorder scene's rule).
            tx.mount(tx.row(() -> {
                var rows = TableItemKaya.rows(tx, items);
                for (var row : rows) {
                    row.row(() -> {
                        row.label(row.name);
                        row.label(row.size);
                    });
                }
                var table = rows.handle;
                // Grown on purpose: ungrown would hug its rows
                // (docs/tables-plan.md decision 8).
                tx.setGrow(table, 1);
                rows.columns(new String[] { "Name", "Size" }, KayaApp.Sort.none());
                app.onSort(table, (t, column) -> {
                    boolean desc = sortedCol == column && !sortedDesc;
                    sortedCol = column;
                    sortedDesc = desc;
                    List<KayaRecords.Entry<String, TableItem>> entries = items.items(t);
                    Comparator<KayaRecords.Entry<String, TableItem>> by = column == 0
                        ? Comparator.comparing(e -> e.value.name())
                        : Comparator.comparing(e -> e.value.size());
                    if (desc) {
                        by = by.reversed();
                    }
                    entries.sort(by);
                    // Keys, never indices.
                    for (var e : entries) {
                        items.moveToEnd(t, e.key);
                    }
                    t.columns(table, new String[] { "Name", "Size" },
                        desc ? KayaApp.Sort.desc(column) : KayaApp.Sort.asc(column));
                });
            }));
            String[][] seeds = { { "b", "banana", "30" }, { "a", "apple", "10" }, { "c", "cherry", "20" } };
            for (String[] seed : seeds) {
                items.insert(tx, seed[0], new TableItem(seed[1], seed[2]));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private Table() {}
}
