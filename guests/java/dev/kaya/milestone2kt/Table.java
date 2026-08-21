package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

import java.util.Comparator;
import java.util.List;

/**
 * The table scene from the JVM: column headers and click-to-sort on
 * the For vocabulary (docs/tables-plan.md). A header click is a
 * REQUEST — this guest reorders its collection BY KEY (the reorder
 * scene's idiom) and re-declares the header with the new indicator;
 * the platform sorts nothing. The byte-frozen contract is
 * tools/scenes/table.steps.
 */
final class Table {
    @KayaGen(key = "String")
    record TableItem(String name, String size) {}

    // The guest's sort policy — the platform never has one: clicking
    // the sorted column flips it, clicking another starts ascending.
    private static long sortedCol = -1;
    private static boolean sortedDesc;

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var items = TableItemKaya.collection(tx);
            // The root is a row so the For's container is the scene's
            // only column-kind widget (the reorder scene's rule). The
            // table IS the For, headers declared on the Widget the
            // template form returns.
            tx.mount(tx.row(() -> {
                var table = TableItemKaya.each(tx, items, row -> {
                    row.row(() -> {
                        row.label(row.name);
                        row.label(row.size);
                    });
                });
                // A table is a viewport: like the scroll scene, the
                // scene says it fills — an ungrown table sizes to
                // nothing (measured by screenshot).
                tx.setGrow(table, 1);
                tx.columns(table, new String[] { "Name", "Size" }, KayaApp.Sort.none());
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
                    // Keys, never indices: moving each key to the end
                    // in the target order leaves the collection sorted.
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
