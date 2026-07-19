package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The entry scene from the JVM: the uncontrolled contract end to end.
 * The field owns its text and reports each edit through onChange; the
 * app folds those into a plain field (draft) — its own model, per
 * doctrine. The add button inserts the draft and answers with the count
 * read from the collection model.
 *
 * <p>The backend selftest (KAYA_SELFTEST=entry) types "milk", clicks
 * add, and expects the status label to read "added milk, 1 total", the
 * field cleared and refocused (the one-shot commands riding the same
 * transaction as the insert), and a second add to answer "nothing to
 * add, 1 total" — proving the clear's text_changed("") re-entered
 * through the normal fold and emptied the draft.
 */
final class Entry {
    /** The scene's handles, returned by the build body. */
    private static final class Scene {
        final KayaApp.Signal<String> status;
        final KayaApp.Widget field;
        final KayaApp.Widget add;
        final KayaApp.Collection todos;

        Scene(KayaApp.Signal<String> status, KayaApp.Widget field, KayaApp.Widget add,
                KayaApp.Collection todos) {
            this.status = status;
            this.field = field;
            this.add = add;
            this.todos = todos;
        }
    }

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this field, not a widget read.
    private static String draft = "";
    private static int nextKey;

    static void app() {
        KayaApp app = new KayaApp();

        Scene scene = app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("no todos");

            KayaApp.Widget column = tx.widget(KayaWire.KIND_COLUMN);
            KayaApp.Widget field = tx.widget(KayaWire.KIND_ENTRY);
            KayaApp.Widget add = tx.widget(KayaWire.KIND_BUTTON);
            tx.setText(add, "add");
            KayaApp.Widget statusLabel = tx.widget(KayaWire.KIND_LABEL);
            tx.bindText(statusLabel, status);

            KayaApp.Collection todos = tx.collection();
            KayaApp.Widget todoList = tx.forEach(todos, t -> {
                KayaApp.Node label = t.widget(KayaWire.KIND_LABEL);
                t.bindTextElement(label, 0);
            });

            tx.addChild(column, field);
            tx.addChild(column, add);
            tx.addChild(column, statusLabel);
            tx.addChild(column, todoList);
            tx.mount(column);
            return new Scene(status, field, add, todos);
        });

        app.onChange(scene.field, (tx, text) -> draft = text);
        app.onClick(scene.add, tx -> {
            // The empty-draft guard every real form has — and the
            // scene's proof that clear emptied the draft through the
            // occurrence fold, not a side assignment.
            if (draft.isEmpty()) {
                tx.write(scene.status, "nothing to add, " + tx.count(scene.todos) + " total");
                return;
            }
            nextKey++;
            tx.insert(scene.todos, "t" + nextKey, draft);
            int total = tx.count(scene.todos);
            tx.write(scene.status, "added " + draft + ", " + total + " total");
            // Finish the form: drop the field's content and put the
            // cursor back, atomically with the insert. The field
            // answers with text_changed("") through its normal edit
            // path, and onChange empties the draft.
            tx.clear(scene.field);
            tx.focus(scene.field);
        });

        app.dispatchLoop();
    }

    private Entry() {}
}
