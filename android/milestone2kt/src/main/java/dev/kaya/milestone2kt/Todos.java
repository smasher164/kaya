package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaRecords;
import dev.kaya.KayaWire;

/**
 * The todos scene from the JVM: records and field projection. The
 * record type is the schema — collectionOf reflects its components
 * once at declaration — the template binds each field to its own
 * widget through typed field tokens, and toggling a row sends one
 * field's delta through updateField: the title never travels.
 */
final class Todos {
    /** The record is the schema. */
    record Todo(String title, boolean done) {}

    // The field tokens, checked against the record at startup.
    private static final KayaRecords.Field<String> FIELD_TITLE =
            KayaRecords.fieldOf(Todo.class, "title", String.class);
    private static final KayaRecords.Field<Boolean> FIELD_DONE =
            KayaRecords.fieldOf(Todo.class, "done", Boolean.class);

    /** The scene's handles, returned by the build body. */
    private static final class Scene {
        final KayaApp.Signal itemsLeft;
        final KayaApp.Widget field;
        final KayaApp.Widget add;
        final KayaRecords.Collection<Todo> todos;
        final KayaApp.Node check;

        Scene(KayaApp.Signal itemsLeft, KayaApp.Widget field, KayaApp.Widget add,
                KayaRecords.Collection<Todo> todos, KayaApp.Node check) {
            this.itemsLeft = itemsLeft;
            this.field = field;
            this.add = add;
            this.todos = todos;
            this.check = check;
        }
    }

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this field, not a widget read.
    private static String draft = "";
    private static int nextKey;

    private static String itemsLeftText(KayaApp.Tx tx, KayaRecords.Collection<Todo> todos) {
        int n = 0;
        for (KayaRecords.Entry<Todo> entry : todos.items(tx)) {
            if (!entry.value.done()) {
                n++;
            }
        }
        return n == 1 ? "1 item left" : n + " items left";
    }

    static void app() {
        KayaApp app = new KayaApp();

        // The template's node handles escape by return, alongside the
        // typed collection.
        final KayaApp.Node[] checkSlot = new KayaApp.Node[1];
        Scene scene = app.build(tx -> {
            KayaApp.Signal itemsLeft = tx.signal("0 items left");

            KayaApp.Widget column = tx.widget(KayaWire.KIND_COLUMN);
            KayaApp.Widget field = tx.widget(KayaWire.KIND_ENTRY);
            KayaApp.Widget add = tx.widget(KayaWire.KIND_BUTTON);
            tx.setText(add, "Add");
            KayaApp.Widget status = tx.widget(KayaWire.KIND_LABEL);
            tx.bindText(status, itemsLeft);

            KayaRecords.Collection<Todo> todos = KayaRecords.collectionOf(tx, Todo.class);
            KayaApp.Widget todoList = tx.forEach(todos.handle, t -> {
                KayaApp.Node row = t.widget(KayaWire.KIND_ROW);
                KayaApp.Node check = t.widget(KayaWire.KIND_CHECKBOX);
                t.bindCheckedField(check, 0, FIELD_DONE);
                KayaApp.Node title = t.widget(KayaWire.KIND_LABEL);
                t.bindTextField(title, 0, FIELD_TITLE);
                t.addChild(row, check);
                t.addChild(row, title);
                checkSlot[0] = check;
            });

            tx.addChild(column, field);
            tx.addChild(column, add);
            tx.addChild(column, status);
            tx.addChild(column, todoList);
            tx.mount(column);
            return new Scene(itemsLeft, field, add, todos, checkSlot[0]);
        });

        app.onChange(scene.field, (tx, text) -> draft = text);
        app.onClick(scene.add, tx -> {
            nextKey++;
            scene.todos.insert(tx, "t" + nextKey, new Todo(draft, false));
            tx.write(scene.itemsLeft, itemsLeftText(tx, scene.todos));
        });
        app.onToggle(scene.check, (tx, keys, checked) -> {
            // One field's delta: the title never travels.
            scene.todos.updateField(tx, keys.get(0), FIELD_DONE, checked);
            tx.write(scene.itemsLeft, itemsLeftText(tx, scene.todos));
        });

        app.dispatchLoop();
    }

    private Todos() {}
}
