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

    private static String itemsLeftText(java.util.List<KayaRecords.Entry<String, Todo>> items) {
        int n = 0;
        for (KayaRecords.Entry<String, Todo> entry : items) {
            if (!entry.value.done()) {
                n++;
            }
        }
        return n == 1 ? "1 item left" : n + " items left";
    }

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaRecords.Collection<String, Todo> todos =
                    KayaRecords.collectionOf(tx, Todo.class);
            // The items-left label is a derived signal: the binding
            // recomputes it from the collection after every mutation,
            // so no handler mentions it.
            KayaApp.Signal<String> itemsLeft = todos.derive(tx, Todos::itemsLeftText);

            tx.mount(tx.column(
                    tx.entry((t, text) -> draft = text),
                    tx.button("Add", t -> {
                        nextKey++;
                        todos.insert(t, "t" + nextKey, new Todo(draft, false));
                    }),
                    tx.label(itemsLeft),
                    tx.forEach(todos.handle, t -> {
                        t.row(
                                todos.checkbox(t, Todo::done, (t2, key, checked) -> {
                                    // One field's delta: the title never
                                    // travels; the derived signal updates
                                    // itself.
                                    todos.patch(t2, key).set(Todo::done, checked);
                                }),
                                todos.label(t, Todo::title));
                    })));
            return null;
        });

        app.dispatchLoop();
    }

    private Todos() {}
}
