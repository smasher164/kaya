package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

/**
 * The undo scene from the JVM — guests/rust/undo.rs, tools/scenes/undo.steps.
 */
public final class Undo {
    /** NAMED FOR ITS SCENE rather than {@code Todo}: the processor writes
     * {@code <Type>Kaya.java} into ONE package and {@code Todos.Todo} got there
     * first. KEYED BY Long because the minter's keys are I64. */
    @KayaGen(key = "Long")
    record UndoTodo(String title) {}

    private static String draft = "";

    /** What is typed in the ROWS, by key. SORTED, because the string it makes
     * is compared byte for byte across every guest and lane. */
    private static final java.util.TreeMap<Long, String> rowNotes = new java.util.TreeMap<>();

    /** kaya invents no name for a typing episode (docs/undo-plan.md D8), so
     * the empty label is the app's to spell. */
    private static String what(String label) {
        return label.isEmpty() ? "typing" : label;
    }

    /** Every key the collection holds, in order — the part of an undo a COUNT
     * cannot see. */
    private static String keyList(KayaApp.Tx tx,
            KayaRecords.Collection<Long, UndoTodo> todos) {
        StringBuilder keys = new StringBuilder();
        for (KayaRecords.Entry<Long, UndoTodo> entry : todos.items(tx)) {
            if (keys.length() > 0) {
                keys.append(',');
            }
            keys.append(entry.key.longValue());
        }
        return keys.length() == 0 ? "no keys" : "keys " + keys;
    }

    /** The row a copy's occurrence names; a wire I64 is a Long here. */
    private static Long rowKey(java.util.List<Object> path) {
        return (Long) path.get(0);
    }

    /** Every note the app holds, by key. An undone note arrives naming
     * (template node, key path), which puts it back in the row it came from. */
    private static String noteList() {
        if (rowNotes.isEmpty()) {
            return "no notes";
        }
        StringBuilder rendered = new StringBuilder();
        for (java.util.Map.Entry<Long, String> note : rowNotes.entrySet()) {
            if (rendered.length() > 0) {
                rendered.append(',');
            }
            rendered.append(note.getKey().longValue()).append('=').append(note.getValue());
        }
        return "notes " + rendered;
    }

    /** One row's note, folded. An empty note is NO note. */
    private static void foldNote(Long key, String text) {
        if (text.isEmpty()) {
            rowNotes.remove(key);
        } else {
            rowNotes.put(key, text);
        }
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.WindowRef win = tx.window(0).title("undo");
            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Undo").role(KayaApp.ROLE_UNDO);
            edit.item("Redo").role(KayaApp.ROLE_REDO);

            KayaApp.Signal<String> status = tx.signal("no todos");
            KayaApp.Signal<String> history = tx.signal("history empty");
            KayaApp.Signal<String> keys = tx.signal("no keys");
            KayaApp.Signal<String> notes = tx.signal("no notes");
            var todos = UndoTodoKaya.collection(tx);

            // PERSISTENT, per window: a history is walked as often as
            // the user likes. The binding has already reconciled its
            // collection model from the payload before this runs, so
            // the count answers about the restored state.
            win.onUndone((t, label, delta) -> {
                absorb(delta);
                t.write(history,
                        "undid " + what(label) + ", " + t.count(todos.handle) + " total");
                // ONE TRANSACTION with the label above: the script reads that
                // label first.
                t.write(keys, keyList(t, todos));
                t.write(notes, noteList());
            }).onRedone((t, label, delta) -> {
                absorb(delta);
                t.write(history,
                        "redid " + what(label) + ", " + t.count(todos.handle) + " total");
                t.write(keys, keyList(t, todos));
                t.write(notes, noteList());
            });

            KayaApp.Widget[] field = new KayaApp.Widget[1];
            KayaApp.Widget root = tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.label(history).a11yId("history"); // label#1
                tx.label(keys).a11yId("keys"); // label#2
                tx.label(notes).a11yId("notes"); // label#3
                field[0] = tx.entry((t, text) -> draft = text).a11yId("draft"); // entry#0
                tx.button("add", t -> add(t, app, status, keys, todos, field[0])); // button#0
                tx.button("star", t -> { // button#1
                    t.undoable("star");
                    t.write(status, "starred");
                });
                // No handler moves the cursor on its own, so the SCRIPT decides
                // focus.
                tx.button("focus", t -> t.focus(field[0])); // button#2
                tx.button("remove", t -> remove(t, status, keys, todos)); // button#3
                for (var row : UndoTodoKaya.rows(tx, todos)) {
                    row.row(() -> {
                        row.label(row.title);
                        // UNBOUND on purpose: the seeded entry(field) overload
                        // would re-push into the field being typed in.
                        KayaApp.Node note = row.entry();
                        // Names no group: the field's own typing undo is the
                        // platform's (D6).
                        app.onChange(note, (t, path, text) -> {
                            foldNote(rowKey(path), text);
                            t.write(notes, noteList());
                        });
                    });
                }
            });
            // The scene types with REAL keystrokes, so something must hold focus.
            tx.focus(field[0]);
            tx.mount(root);
        });

        app.dispatchLoop();
    }

    /** The texts the core put back. THE DELTA IS THE ONLY NOTIFICATION:
     * restoring is a programmatic write and never echoes (D5). */
    private static void absorb(KayaApp.UndoDelta delta) {
        for (KayaApp.UndoText text : delta.texts()) {
            if (text.path().isEmpty()) {
                draft = text.text();
            } else {
                foldNote(rowKey(text.path()), text.text());
            }
        }
    }

    private static void add(KayaApp.Tx tx, KayaApp app, KayaApp.Signal<String> status,
            KayaApp.Signal<String> keys, KayaRecords.Collection<Long, UndoTodo> todos,
            KayaApp.Widget field) {
        if (draft.isEmpty()) {
            tx.write(status, "nothing to add, " + tx.count(todos.handle) + " total");
            return;
        }
        tx.undoable("add " + draft);
        // The binding mints the key (docs/fresh-key-plan.md): a static counter
        // would not survive an undo that rewound it.
        KayaRecords.insertFresh(tx, todos, new UndoTodo(draft));
        tx.write(status, "added " + draft + ", " + tx.count(todos.handle) + " total");
        tx.write(keys, keyList(tx, todos));
        // A pure effect rides along and is not restored (A2).
        tx.focus(field);
        // `clear` inside a named group is refused at apply (D4).
        app.post(t -> t.clear(field));
    }

    /** The step whose inverse is an IDENTITY, not a content: the core captured
     * the entry and its order, so this app remembers neither. */
    private static void remove(KayaApp.Tx tx, KayaApp.Signal<String> status,
            KayaApp.Signal<String> keys, KayaRecords.Collection<Long, UndoTodo> todos) {
        var items = todos.items(tx);
        if (items.isEmpty()) {
            tx.write(status, "nothing to remove, " + tx.count(todos.handle) + " total");
            return;
        }
        KayaRecords.Entry<Long, UndoTodo> first = items.get(0);
        tx.undoable("remove " + first.value.title());
        tx.remove(todos.handle, first.key);
        tx.write(status,
                "removed " + first.value.title() + ", " + tx.count(todos.handle) + " total");
        tx.write(keys, keyList(tx, todos));
    }

    private Undo() {}
}
