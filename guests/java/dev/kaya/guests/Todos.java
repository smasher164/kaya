package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

/**
 * The todos scene from the JVM: the record type is the schema, and the
 * typed collection's checkbox hands its handler the stamped copy's key.
 *
 * <p>The DERIVED label survives an undo with nobody restoring it — the
 * derive's write rides the insert's named transaction — which is why
 * this file registers no {@code onUndone} (see
 * {@code KayaApp.absorbUndo}).
 */
public final class Todos {
        /**
         * The annotation processor reads this and generates TodoKaya: the
         * collection factory, the field tokens and the named-setter patch.
         *
         * <p>KEYED BY Long because the key comes from {@code insertFresh}
         * and the minter's keys are I64.
         */
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
            // The two items are the whole undo surface an app declares;
            // they work out their own enablement (docs/undo-plan.md).
            KayaApp.WindowRef win = tx.window(0).title("todos");
            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Undo").role(KayaApp.ROLE_UNDO);
            edit.item("Redo").role(KayaApp.ROLE_REDO);

            var todos = TodoKaya.collection(tx);
            // A derived signal: recomputed after every mutation, so no
            // handler mentions it.
            KayaApp.Signal<String> itemsLeft = todos.derive(tx, Todos::itemsLeftText);

            tx.mount(tx.column(() -> {
                var field = tx.entry((t, text) -> draft = text);
                tx.button("Add", t -> {
                    if (draft.isEmpty()) {
                        return;
                    }
                    // Naming the transaction is the whole undo surface;
                    // the derive's write rides this same batch.
                    t.undoable("add " + draft);
                    KayaRecords.insertFresh(t, todos, new Todo(draft, false));
                    // FINISHING THE FORM IS NOT PART OF THE STEP, so
                    // the clear goes in the NEXT transaction — and
                    // `clear` inside a named group is refused at apply
                    // anyway (docs/undo-plan.md D4).
                    app.post(t2 -> {
                        t2.clear(field);
                        t2.focus(field);
                    });
                });
                tx.label(itemsLeft);
                for (var row : TodoKaya.rows(tx, todos)) {
                    row.row(() -> {
                        row.checkbox(row.done, (t2, key, checked) -> {
                            // One field's delta through the generated
                            // named setter: the title never travels.
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
