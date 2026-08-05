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
                    // NO KEY, AND NO COUNTER TO GET WRONG: the
                    // binding mints the name and hands it back
                    // (docs/fresh-key-plan.md). This app has no use
                    // for the returned key — the checkbox's own
                    // stamped path names its row — so the call is
                    // made for effect.
                    KayaRecords.insertFresh(t, todos, new Todo(draft, false));
                    // Finish the form: the field empties on screen and
                    // reports text_changed("") through its normal edit
                    // path (the fold empties the draft), and the
                    // cursor lands back in it.
                    t.clear(field);
                    t.focus(field);
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
