package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

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
     */
    @KayaGen(key = "String")
    record UndoTodo(String title) {}

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this field, not a widget read.
    private static String draft = "";
    private static int nextKey;

    /**
     * What the history label says a step was. A typing episode has no
     * authored name and kaya invents none ("Undo Typing" is an Apple
     * convention, not a scene string — docs/undo-plan.md D8), so the
     * empty label is the app's to spell.
     */
    private static String what(String label) {
        return label.isEmpty() ? "typing" : label;
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
            }).onRedone((t, label, delta) -> {
                absorb(delta);
                t.write(history,
                        "redid " + what(label) + ", " + t.count(todos.handle) + " total");
            });

            KayaApp.Widget[] field = new KayaApp.Widget[1];
            KayaApp.Widget root = tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.label(history).a11yId("history"); // label#1
                field[0] = tx.entry((t, text) -> draft = text).a11yId("draft"); // entry#0
                tx.button("add", t -> add(t, app, status, todos, field[0])); // button#0
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
                for (var row : UndoTodoKaya.rows(todos)) {
                    row.row(() -> row.label(row.title));
                }
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
     * The text the core put back, into the app's own copy of the draft.
     *
     * <p>THE DELTA IS THE ONLY NOTIFICATION for that text: restoring an
     * episode is a programmatic write, and a programmatic write never
     * echoes, so an app that folds text changes into its own model —
     * which is every app, the field being uncontrolled — would go stale
     * on exactly this step if the payload did not carry it (D5).
     */
    private static void absorb(KayaApp.UndoDelta delta) {
        if (!delta.texts().isEmpty()) {
            draft = delta.texts().get(delta.texts().size() - 1).text();
        }
    }

    private static void add(KayaApp.Tx tx, KayaApp app, KayaApp.Signal<String> status,
            KayaRecords.Collection<String, UndoTodo> todos, KayaApp.Widget field) {
        if (draft.isEmpty()) {
            tx.write(status, "nothing to add, " + tx.count(todos.handle) + " total");
            return;
        }
        nextKey++;
        // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name is what
        // the step is called; everything in this batch is what it did.
        tx.undoable("add " + draft);
        todos.insert(tx, "t" + nextKey, new UndoTodo(draft));
        tx.write(status, "added " + draft + ", " + tx.count(todos.handle) + " total");
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

    private Undo() {}
}
