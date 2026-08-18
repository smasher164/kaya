package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

import java.util.List;

/**
 * The reorder scene from the JVM: order as collection data. Each
 * handler repositions an entry BY KEY and expect_order reads the
 * toolkit's actual child order back.
 *
 * <p>THE ROOT IS A ROW so the For's container is the scene's only
 * column-kind widget: languages disagree on whether containers are
 * created before or after their children, and column#0 must name the
 * same widget everywhere.
 */
final class Reorder {
    /** The annotation processor reads this and generates ItemKaya. */
    @KayaGen(key = "String")
    record Item(String title) {}

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var items = ItemKaya.collection(tx);

            tx.mount(tx.row(() -> {
                tx.button("rotate", t -> {
                    // First entry to the end. The model owns the order,
                    // so the handler asks it which key is first rather
                    // than counting widgets.
                    List<KayaRecords.Entry<String, Item>> entries = items.items(t);
                    items.moveToEnd(t, entries.get(0).key);
                });
                tx.button("lift", t -> {
                    // Last entry to the front, keys never indices.
                    List<KayaRecords.Entry<String, Item>> entries = items.items(t);
                    items.moveToFront(t, entries.get(entries.size() - 1).key);
                });
                for (var row : ItemKaya.rows(items)) {
                    row.label(row.title);
                }
            }));
            for (String key : new String[] { "a", "b", "c" }) {
                items.insert(tx, key, new Item(key));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private Reorder() {}
}
