package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

import java.util.List;

/**
 * The reorder scene from the JVM — guests/rust/reorder.rs,
 * tools/scenes/reorder.steps.
 */
public final class Reorder {
    @KayaGen(key = "String")
    record Item(String title) {}

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var items = ItemKaya.collection(tx);

            tx.mount(tx.row(() -> {
                tx.button("rotate", t -> {
                    List<KayaRecords.Entry<String, Item>> entries = items.items(t);
                    items.moveToEnd(t, entries.get(0).key);
                });
                tx.button("lift", t -> {
                    // Last entry to the front, keys never indices.
                    List<KayaRecords.Entry<String, Item>> entries = items.items(t);
                    items.moveToFront(t, entries.get(entries.size() - 1).key);
                });
                for (var row : ItemKaya.rows(tx, items)) {
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
