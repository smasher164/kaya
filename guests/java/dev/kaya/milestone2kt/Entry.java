package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The entry scene from the JVM: the uncontrolled contract end to end.
 * The field owns its text and reports each edit through onChange; the
 * app folds those into a plain field (draft) — its own model, per
 * doctrine. The add button inserts the draft and answers with the count
 * read from the collection model.
 *
 * <p>WHAT THIS SCENE DOCUMENTS IS THE EVENT SIDE, and only that
 * (DESIGN.md, the scope ratified 2026-08-05). Handlers are registered
 * CENTRALLY, after the build, against the handles the build body handed
 * back — the tier below the co-located closures every other JVM scene
 * carries ({@code tx.button("add", t -> ...)} in Todos, Undo, Menus).
 * Both spellings are real Java and the binding offers both; this file
 * is where the plain one is written down. Construction is ordinary
 * sugar here, as in every example that is not a C guest.
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

    static void app() {
        KayaApp app = new KayaApp();

        Scene scene = app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("no todos");
            KayaApp.Collection todos = tx.collection();

            // Java lambdas cannot assign captured locals, so the two
            // handles the registrations below need come back out of the
            // container body through one-slot arrays (Clipboard.java's
            // idiom, and Undo.java's).
            KayaApp.Widget[] field = new KayaApp.Widget[1];
            KayaApp.Widget[] add = new KayaApp.Widget[1];
            tx.mount(tx.column(() -> {
                // The handler-free constructors, on purpose: this scene
                // registers centrally, so the sugar it takes is the
                // construction half alone.
                field[0] = tx.entry(); // entry#0
                add[0] = tx.button("add"); // button#0
                tx.label(status); // label#0
                // The tracing tier: the for-each IS the For — the body
                // runs once, and value() is the element's own token. A
                // scalar collection has exactly one field, the element
                // itself, which is what an index used to spell.
                for (var row : todos.rows()) {
                    row.label(row.value());
                }
            }));
            return new Scene(status, field[0], add[0], todos);
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
            // NO KEY, AND NO COUNTER TO GET WRONG: a todo here is a
            // title and nothing else, so the binding mints the name and
            // hands it back (docs/fresh-key-plan.md). This app has no
            // use for the returned key — nothing looks a todo up — so
            // the call is made for effect, which in Java is a bare
            // statement.
            tx.insertFresh(scene.todos, draft);
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
