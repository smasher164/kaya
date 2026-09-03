package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

/**
 * The todos scene from the JVM — guests/rust/todos.rs, tools/scenes/todos.steps.
 */
public final class Todos {
    /** The annotation processor reads this and generates TodoKaya. KEYED BY
     * Long because the minter's keys are I64. */
    @KayaGen(key = "Long")
    record Todo(String title, boolean done) {}

    private static String draft = "";

    private static String itemsLeftText(java.util.List<KayaRecords.Entry<Long, Todo>> items) {
        int n = 0;
        for (KayaRecords.Entry<Long, Todo> entry : items) {
            if (!entry.value.done()) {
                n++;
            }
        }
        return n == 1 ? "1 item left" : n + " items left";
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // The two items are the whole undo surface an app declares.
            KayaApp.WindowRef win = tx.window(0).title("todos");
            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Undo").role(KayaApp.ROLE_UNDO);
            edit.item("Redo").role(KayaApp.ROLE_REDO);

            var todos = TodoKaya.collection(tx);
            KayaApp.Signal<String> itemsLeft = todos.derive(tx, Todos::itemsLeftText);

            tx.mount(tx.column(() -> {
                var field = tx.entry((t, text) -> draft = text);
                tx.button("Add", t -> {
                    if (draft.isEmpty()) {
                        return;
                    }
                    // The derive's write rides this same batch.
                    t.undoable("add " + draft);
                    KayaRecords.insertFresh(t, todos, new Todo(draft, false));
                    // `clear` inside a named group is refused at apply
                    // (docs/undo-plan.md D4).
                    app.post(t2 -> {
                        t2.clear(field);
                        t2.focus(field);
                    });
                });
                tx.label(itemsLeft);
                for (var row : TodoKaya.rows(tx, todos)) {
                    row.row(() -> {
                        row.checkbox(row.done, (t2, key, checked) -> {
                            TodoKaya.patch(t2, todos, key).done(checked);
                        });
                        row.label(row.title);
                    });
                }
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Todos() {}
}
