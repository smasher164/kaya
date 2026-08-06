package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;
import dev.kaya.KayaWire;

/**
 * The undo scene from the JVM: two tiers, one Edit menu, and one ledger
 * that orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).
 *
 * <p>WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP.
 * {@code tx.undoable(...)} names a transaction, and that name is the
 * step: the core keeps the inverse of what the batch did to signals and
 * collections, and hands it back through the window's {@code onUndone}.
 * There is no undo stack in this file, no command objects, and no re-run
 * of any handler — an undo is a programmatic write of the state that was
 * there before, which is why it emits nothing and why the occurrence
 * carries the whole delta.
 *
 * <p>THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S, and this app writes
 * nothing for it at all. Both tiers arrive through the same Edit&gt;Undo
 * item, and which one answers is kaya's routing question, not the app's
 * (D6).
 *
 * <p>THE SCENARIO THAT MOTIVATED THE MILESTONE is the add button, which
 * is the entry scene's add: it appends a todo AND empties the field. Two
 * transactions, deliberately — the undoable group is the insert and the
 * status it wrote, and the clear that finishes the form is not part of
 * the step. Under two unordered stacks one Cmd+Z takes back the CLEAR:
 * "milk" returns to the field, the todo stays, and the user is looking
 * at a state that never existed (docs/undo-plan.md §2). Here it takes
 * back the ADD.
 *
 * <p>It is also the design saying the same thing twice: {@code clear}
 * inside a group is REFUSED at apply, because it destroys widget-owned
 * text the core never held (D4). Undo restores state, and state is
 * signals plus collections.
 *
 * <p>AND THE APP NAMES NO TODO. A todo is a title and nothing else — it
 * has no identity of its own — so the key comes from
 * {@code insertFresh}, which mints one per collection instance and
 * hands it back (docs/fresh-key-plan.md). What that buys here is the
 * whole point of the minter: this file used to carry {@code nextKey}, a
 * static counter beside the collection whose safety rested on never
 * rewinding, and an undo that rewound it would have handed the same
 * name to two todos.
 *
 * <p>Canonical semantics in guests/rust/undo.rs; the byte-frozen
 * contract in tools/scenes/undo.steps.
 */
final class Undo {
    /**
     * The record is the schema.
     *
     * <p>NAMED FOR ITS SCENE rather than {@code Todo}, and that is a
     * JVM-only cost worth stating: the annotation processor writes
     * {@code <Type>Kaya.java} into ONE package shared by every scene in
     * this guest, so two records of the same simple name would generate
     * the same file. {@code Todos.Todo} got there first. Nothing about
     * the name reaches the wire or a scene string.
     *
     * <p>KEYED BY Long, because the minter's keys are I64 and the
     * generated surface carries the key type: the annotation is what
     * makes {@code UndoTodoKaya.collection} a
     * {@code Collection<Long, UndoTodo>}, and a guest that adopted
     * {@code insertFresh} without moving this would not compile.
     */
    @KayaGen(key = "Long")
    record UndoTodo(String title) {}

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is these two, not a widget read. Two of them, because there
    // are two kinds of text field on screen — the draft, and one per
    // row — and the payload's path is what tells them apart.
    private static String draft = "";

    /**
     * What is typed in the ROWS, by key. Sorted, because the rendering
     * below walks it in ascending key order and the string it makes is
     * compared byte-for-byte across every guest and every lane
     * (invariant 6).
     */
    private static final java.util.TreeMap<Long, String> rowNotes = new java.util.TreeMap<>();

    /**
     * What the history label says a step was. A typing episode has no
     * authored name and kaya invents none ("Undo Typing" is an Apple
     * convention, not a scene string — docs/undo-plan.md D8), so the
     * empty label is the app's to spell.
     */
    private static String what(String label) {
        return label.isEmpty() ? "typing" : label;
    }

    /**
     * The app's collection mirror, rendered: every key it holds, in the
     * order it holds them.
     *
     * <p>THIS IS THE ONLY PART OF AN UNDO A COUNT CANNOT SEE. A
     * restored entry that came back under a fresh name, or at the end
     * instead of where it was, leaves every total in this file correct
     * — the entries and orders runs of the delta are what say
     * otherwise, and this is where the scene reads them (D5).
     */
    private static String keyList(KayaApp.Tx tx,
            KayaRecords.Collection<Long, UndoTodo> todos) {
        StringBuilder keys = new StringBuilder();
        for (KayaRecords.Entry<Long, UndoTodo> entry : todos.items(tx)) {
            if (keys.length() > 0) {
                keys.append(',');
            }
            // The minter's keys are I64, and Long's own decimal
            // spelling is what turns one back into a scene string.
            keys.append(entry.key.longValue());
        }
        return keys.length() == 0 ? "no keys" : "keys " + keys;
    }

    /**
     * The row a stamped copy's occurrence names: the copy's key path,
     * which for a top-level For is one key — the todo's own, minted by
     * {@code insertFresh}. The minter's keys are I64, and a wire I64 is
     * a Long here, exactly as {@code keyList} reads the collection's
     * keys.
     */
    private static Long rowKey(java.util.List<Object> path) {
        return (Long) path.get(0);
    }

    /**
     * The app's copy of what is typed in the ROWS, rendered: every note
     * it holds, by key.
     *
     * <p>THE ROWS' FIELDS ARE UNCONTROLLED LIKE THE DRAFT, so this map
     * is the app's own and nothing reads it back off a widget. It is
     * also where this scene proves the payload's shape: an undone note
     * arrives naming (template node, key path), and an app with two rows
     * can only put it back in the right one because the path says which.
     */
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

    /**
     * One row's note, folded — the rule both arrival paths share, so
     * the script's assertion cannot pass through a second spelling of
     * "what a note is": the row's own edit writes it, and the delta that
     * restores that field writes it again.
     *
     * <p>AN EMPTY NOTE IS NO NOTE, which is what makes the scene's undo
     * falsifiable: restoring a row's field to "" has to REMOVE the key,
     * so an app that ignored the payload's instance texts reads its
     * stale note back out and the script says so.
     */
    private static void foldNote(Long key, String text) {
        if (text.isEmpty()) {
            rowNotes.remove(key);
        } else {
            rowNotes.put(key, text);
        }
    }

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // THE GESTURE LAYER, one tier deeper: an app declares the
            // two items and writes nothing else. They act on the focused
            // widget, lower to the platform's own command where it has
            // one, and work out their own enablement from what is
            // focused and what the ledger holds.
            KayaApp.WindowRef win = tx.window(0).title("undo");
            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Undo").role(KayaApp.ROLE_UNDO);
            edit.item("Redo").role(KayaApp.ROLE_REDO);

            KayaApp.Signal<String> status = tx.signal("no todos");
            KayaApp.Signal<String> history = tx.signal("history empty");
            KayaApp.Signal<String> keys = tx.signal("no keys");
            KayaApp.Signal<String> notes = tx.signal("no notes");
            var todos = UndoTodoKaya.collection(tx);

            // THE HANDLERS RIDE THE WINDOW CONSTRUCT, because handlers
            // scope to the thing that creates them and an undo is always
            // some window's. Per window, and PERSISTENT: a history is
            // walked as often as the user likes. The binding has already
            // reconciled its collection model from this payload before
            // the handler runs, which is why the count below answers
            // about the restored state.
            win.onUndone((t, label, delta) -> {
                absorb(delta);
                t.write(history,
                        "undid " + what(label) + ", " + t.count(todos.handle) + " total");
                // ONE TRANSACTION WITH THE LABEL ABOVE, deliberately:
                // the script reads that label first, so by the time it
                // reads this one the app's own answer is what is on
                // screen — not the value the core restored on its way
                // past. The notes ride the same transaction for the same
                // reason.
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
                // A group at its smallest: one signal write, which is
                // the undoable set's whole vocabulary on the reactive
                // side.
                tx.button("star", t -> { // button#1
                    t.undoable("star");
                    t.write(status, "starred");
                });
                // THE SCENE'S WAY BACK TO THE FIELD. `star` does not
                // move the cursor on its own — an app that reaches for
                // focus after every action is deciding where the user is
                // looking — so the scene says so itself, and the routing
                // question ("what is focused?") stays visible in the
                // script rather than hidden in a handler.
                tx.button("focus", t -> t.focus(field[0])); // button#2
                tx.button("remove", t -> remove(t, status, keys, todos)); // button#3
                // THE TEMPLATE HANDLE ITSELF, not the generated typed
                // row: the row now holds a field, and the template tier
                // has label/checkbox/button sugar and no `entry` in ANY
                // binding — there is no source to bind an uncontrolled
                // field to — so the widget-kind floor is the spelling
                // everywhere, and in Java it lives on the Tpl. The
                // title stays on the typed field token, which is the
                // same call the generated row would have made.
                tx.forEach(todos.handle, tpl -> {
                    tpl.row(() -> {
                        tpl.label(UndoTodoKaya.TITLE);
                        // THE ROW'S OWN FIELD, and the reason this scene
                        // grew: a copy's text edits are the same
                        // occurrence a live field's are, one identity
                        // deeper, and the ledger banks them the same way
                        // now that the payload can name them.
                        KayaApp.Node note = tpl.widget(KayaWire.KIND_ENTRY);
                        // ITS OWN TRANSACTION, and not an undoable one:
                        // the handler was handed the transaction, and
                        // nothing in it names a group — the field's own
                        // typing undo is the platform's (D6).
                        app.onChange(note, (t, path, text) -> {
                            foldNote(rowKey(path), text);
                            t.write(notes, noteList());
                        });
                    });
                });
            });
            // THE SCENE TYPES WITH REAL KEYSTROKES, so something has to
            // be holding focus when it does — and focus is the routing
            // question's other half.
            tx.focus(field[0]);
            tx.mount(root);
        });

        app.dispatchLoop();
    }

    /**
     * The texts the core put back, into the app's own copies of them.
     *
     * <p>THE DELTA IS THE ONLY NOTIFICATION for that text: restoring an
     * episode is a programmatic write, and a programmatic write never
     * echoes, so an app that folds text changes into its own model —
     * which is every app, the field being uncontrolled — would go stale
     * on exactly this step if the payload did not carry it (D5).
     *
     * <p>THE RUN IS WALKED WHOLE, not reduced to its last entry, because
     * an entry NAMES the field it restores: the empty path is the draft,
     * and a path names the row whose note came back.
     */
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
            // NOT A STEP, so it names no group and the forward history
            // survives it. It is also the one place this app READS ITS
            // OWN DRAFT out loud, which is how the script proves the
            // restored text of an undone typing episode reached it at
            // all.
            tx.write(status, "nothing to add, " + tx.count(todos.handle) + " total");
            return;
        }
        // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name is what
        // the step is called; everything in this batch is what it did.
        tx.undoable("add " + draft);
        // NO KEY, AND NO COUNTER TO GET WRONG: the binding mints the
        // name and hands it back. This app has no use for it — a todo
        // is looked up by nothing — and an app that does (selecting the
        // new row, say) takes it from here rather than inventing a
        // second name for the same datum.
        KayaRecords.insertFresh(tx, todos, new UndoTodo(draft));
        tx.write(status, "added " + draft + ", " + tx.count(todos.handle) + " total");
        tx.write(keys, keyList(tx, todos));
        // A PURE EFFECT rides along and is simply not restored: undo
        // restores state, not where you were looking (A2).
        tx.focus(field);
        // FINISHING THE FORM IS NOT PART OF THE STEP. Its own
        // transaction — post is this binding's spelling for "the next
        // one, after this", the handler being the transaction — so
        // undoing the add does not put the draft back beside a todo that
        // is gone, and `clear` inside a group would be refused anyway.
        // The field empties on screen and reports its text change
        // through the normal edit path, so the fold above empties the
        // draft.
        app.post(t -> t.clear(field));
    }

    /**
     * THE STEP WHOSE INVERSE IS AN IDENTITY, not a content. The core
     * captured the entry and the instance's order before the removal,
     * so undoing this puts the entry back under the key it already had,
     * where it already was — neither of which this app has to remember.
     *
     * <p>The target is the collection's FIRST entry, taken from the
     * app's own model and never from a widget, so the entry that comes
     * back has to come back BEFORE the one that stayed.
     */
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
