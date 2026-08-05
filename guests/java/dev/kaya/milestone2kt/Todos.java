package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

/**
 * The todos scene from the JVM, on the construction sugar: the record
 * type is the schema, constructors carry their handlers (the Swing
 * JButton(Action) shape), containers take their children, and the
 * typed collection's checkbox hands its handler the stamped
 * copy's key — no Object in sight. The C guests keep the explicit floor
 * on purpose.
 *
 * <p>AND THE DERIVED LABEL SURVIVES AN UNDO WITH NOBODY RESTORING IT.
 * The add is a named step ({@code tx.undoable}), and the derive's write
 * is in that same batch — the binding recomputes after the insert and
 * writes an ordinary signal into the transaction that caused it — so
 * the core banks the label in both directions of the step and hands it
 * back together with the collection. That is why this file registers no
 * {@code onUndone}: there is nothing for a handler to put right, and a
 * binding that recomputed the derive while absorbing the payload would
 * be writing a value the ledger never banked (the stance is written
 * down at {@code KayaApp.absorbUndo}).
 */
final class Todos {
    /**
     * The record is the schema; the annotation processor reads it and
     * generates TodoKaya: the collection factory, exact-index field
     * tokens, and the named-setter patch.
     *
     * <p>KEYED BY Long, because a todo here is a title and a done flag
     * and neither of them identifies it — the key comes from
     * {@code insertFresh} and the minter's keys are I64. The annotation
     * is what makes the generated surface a
     * {@code Collection<Long, Todo>}, down to the row checkbox's
     * {@code ToggleHandler<Long>}.
     */
    @KayaGen(key = "Long")
    record Todo(String title, boolean done) {}

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this field, not a widget read.
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

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // THE GESTURE LAYER, and the two items are the whole of it:
            // this app declares them and writes nothing else. They act
            // on what is focused, lower to the platform's own command
            // where it has one, and work out their own enablement from
            // what the ledger holds (docs/undo-plan.md D1-D6).
            KayaApp.WindowRef win = tx.window(0).title("todos");
            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Undo").role(KayaApp.ROLE_UNDO);
            edit.item("Redo").role(KayaApp.ROLE_REDO);

            var todos = TodoKaya.collection(tx);
            // The items-left label is a derived signal: the binding
            // recomputes it from the collection after every mutation,
            // so no handler mentions it.
            KayaApp.Signal<String> itemsLeft = todos.derive(tx, Todos::itemsLeftText);

            tx.mount(tx.column(() -> {
                var field = tx.entry((t, text) -> draft = text);
                tx.button("Add", t -> {
                    if (draft.isEmpty()) {
                        return;
                    }
                    // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. What
                    // makes the ITEMS-LEFT LABEL come back with the todo
                    // is that the derive's write is in this batch:
                    // insertFresh recomputes every derived signal rooted
                    // at the collection and writes them into the
                    // transaction that caused them, and a named
                    // transaction banks every signal it dirtied in both
                    // directions. So the step's inverse carries
                    // "0 items left" and its forward carries "1 item
                    // left", and the label is restored by the same
                    // mechanism as the collection.
                    t.undoable("add " + draft);
                    // NO KEY, AND NO COUNTER TO GET WRONG: the
                    // binding mints the name and hands it back
                    // (docs/fresh-key-plan.md). This app has no use
                    // for the returned key — the checkbox's own
                    // stamped path names its row — so the call is
                    // made for effect.
                    KayaRecords.insertFresh(t, todos, new Todo(draft, false));
                    // FINISHING THE FORM IS NOT PART OF THE STEP. A
                    // handler IS a transaction here, so post is this
                    // binding's spelling for "the next one, after this":
                    // undoing the add does not put the draft back beside
                    // a todo that is gone, and `clear` inside a group
                    // would be refused at apply anyway (D4), because it
                    // destroys widget-owned text the core never held.
                    // The field empties on screen and reports
                    // text_changed("") through its normal edit path (the
                    // fold empties the draft), and the cursor lands back
                    // in it.
                    app.post(t2 -> {
                        t2.clear(field);
                        t2.focus(field);
                    });
                });
                tx.label(itemsLeft);
                // The tracing tier: the for-each IS the For — the body
                // runs once over the generated row surface
                // (exact-index tokens, no probes); a break is caught
                // at submit.
                for (var row : TodoKaya.rows(todos)) {
                    row.row(() -> {
                        row.checkbox(row.done, (t2, key, checked) -> {
                            // One field's delta through the generated
                            // named setter: the title never travels;
                            // the derived signal updates itself.
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
