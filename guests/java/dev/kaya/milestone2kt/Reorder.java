package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

import java.util.List;

/**
 * The reorder scene from the JVM: order as collection data, end to
 * end. Three stamped rows and two buttons that never touch a widget —
 * each handler repositions an entry by key (collection_move on the
 * wire, move_child at the toolkit), and the selftest's expect_order
 * reads the toolkit's actual child order back. The root is a row so
 * the For's container is the scene's only column-kind widget:
 * languages disagree on whether containers are created before or
 * after their children, and column#0 must name the same widget
 * everywhere.
 */
final class Reorder {
    /** The record is the schema; the annotation processor reads it
     * and generates ItemKaya, the collection factory. */
    @KayaGen(key = "String")
    record Item(String title) {}

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var items = ItemKaya.collection(tx);

            tx.mount(tx.row(
                    tx.button("rotate", t -> {
                        // First entry to the end. The model owns the
                        // order, so the handler asks it which key is
                        // first — it never counts widgets.
                        List<KayaRecords.Entry<String, Item>> entries = items.items(t);
                        items.moveToEnd(t, entries.get(0).key);
                    }),
                    tx.button("lift", t -> {
                        // Last entry to the front: moveToFront is
                        // sugar for moveBefore the current first key —
                        // the same wire op, keys never indices.
                        List<KayaRecords.Entry<String, Item>> entries = items.items(t);
                        items.moveToFront(t, entries.get(entries.size() - 1).key);
                    }),
                    ItemKaya.each(tx, items, (t, row) -> {
                        row.label(t, row.title);
                    })));
            for (String key : new String[] { "a", "b", "c" }) {
                items.insert(tx, key, new Item(key));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private Reorder() {}
}
