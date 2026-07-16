package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaRecords;

/**
 * The todos scene from the JVM, on the construction sugar: the record
 * type is the schema, constructors carry their handlers (the Swing
 * JButton(Action) shape), containers take their children, and the
 * typed collection's checkbox hands its handler the stamped
 * copy's key — no Object in sight. Milestone2 keeps the explicit floor
 * on purpose.
 */
final class Todos {
    /** The record is the schema. */
    record Todo(String title, boolean done) {}

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this field, not a widget read.
    private static String draft = "";
    private static int nextKey;

    private static String itemsLeftText(KayaApp.Tx tx,
            KayaRecords.Collection<String, Todo> todos) {
        int n = 0;
        for (KayaRecords.Entry<String, Todo> entry : todos.items(tx)) {
            if (!entry.value.done()) {
                n++;
            }
        }
        return n == 1 ? "1 item left" : n + " items left";
    }

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> itemsLeft = tx.signal("0 items left");
            KayaRecords.Collection<String, Todo> todos =
                    KayaRecords.collectionOf(tx, Todo.class);

            tx.mount(tx.column(
                    tx.entry((t, text) -> draft = text),
                    tx.button("Add", t -> {
                        nextKey++;
                        todos.insert(t, "t" + nextKey, new Todo(draft, false));
                        t.write(itemsLeft, itemsLeftText(t, todos));
                    }),
                    tx.label(itemsLeft),
                    tx.forEach(todos.handle, t -> {
                        t.row(
                                todos.checkbox(t, Todo::done, (t2, key, checked) -> {
                                    // One field's delta: the title never travels.
                                    todos.patch(t2, key).set(Todo::done, checked);
                                    t2.write(itemsLeft, itemsLeftText(t2, todos));
                                }),
                                todos.label(t, Todo::title));
                    })));
            return null;
        });

        app.dispatchLoop();
    }

    private Todos() {}
}
