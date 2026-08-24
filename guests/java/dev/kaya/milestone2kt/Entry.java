package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The entry scene from the JVM: the uncontrolled contract end to end.
 *
 * <p>This is the scene that spells CENTRAL handler registration — after
 * the build, against the handles the build body handed back. The
 * co-located spelling ({@code tx.button("add", t -> ...)}) is in Todos,
 * Undo and Menus; the binding offers both.
 */
final class Entry {
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

    private static String draft = "";

    static void app() {
        KayaApp app = new KayaApp();

        Scene scene = app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("no todos");
            KayaApp.Collection todos = tx.collection();

            // Java lambdas cannot assign captured locals, so handles
            // declared inside a container body come back out through
            // one-slot arrays.
            KayaApp.Widget[] field = new KayaApp.Widget[1];
            KayaApp.Widget[] add = new KayaApp.Widget[1];
            tx.mount(tx.column(() -> {
                field[0] = tx.entry(); // entry#0
                add[0] = tx.button("add"); // button#0
                tx.label(status); // label#0
                for (var row : tx.rows(todos)) {
                    row.label(row.value());
                }
            }));
            return new Scene(status, field[0], add[0], todos);
        });

        app.onChange(scene.field, (tx, text) -> draft = text);
        app.onClick(scene.add, tx -> {
            if (draft.isEmpty()) {
                tx.write(scene.status, "nothing to add, " + tx.count(scene.todos) + " total");
                return;
            }
            // The binding mints the key (docs/fresh-key-plan.md); this
            // app has no use for the one it hands back.
            tx.insertFresh(scene.todos, draft);
            int total = tx.count(scene.todos);
            tx.write(scene.status, "added " + draft + ", " + total + " total");
            // The field answers the clear with text_changed("") through
            // its normal edit path, so onChange empties the draft.
            tx.clear(scene.field);
            tx.focus(scene.field);
        });

        app.dispatchLoop();
    }

    private Entry() {}
}
