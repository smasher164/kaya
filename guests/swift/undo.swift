// The undo scene, Swift port: two tiers, one Edit menu, and one ledger
// that orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).
//
// WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. `tx.undoable(...)`
// names a transaction, and that name is the step: the core keeps the
// inverse of what the batch did to signals and collections, and hands it
// back through the window's onUndone. There is no undo stack in this
// file, no command objects, and no re-run of any handler — an undo is a
// programmatic write of the state that was there before, which is why it
// emits nothing and why the occurrence carries the whole delta.
//
// THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S, and this app writes
// nothing for it at all. Both tiers arrive through the same Edit>Undo
// item, and which one answers is kaya's routing question, not the app's
// (D6).
//
// THE SCENARIO THAT MOTIVATED THE MILESTONE is the add button, which is
// the entry scene's add: it appends a todo AND empties the field. Two
// transactions, deliberately — the undoable group is the insert and the
// status it wrote, and the clear that finishes the form is not part of
// the step. Under two unordered stacks one Cmd+Z takes back the CLEAR:
// "milk" returns to the field, the todo stays, and the user is looking at
// a state that never existed (docs/undo-plan.md §2). Here it takes back
// the ADD.
//
// It is also the design saying the same thing twice: `clear` inside a
// group is REFUSED at apply, because it destroys widget-owned text the
// core never held (D4). Undo restores state, and state is signals plus
// collections.
//
// See the canonical semantics in guests/rust/undo.rs and
// tools/scenes/undo.steps.

import Foundation

struct Todo: KayaGen {
    var title: String
}

let app = KayaApp()

// The fold: widget-owned state arrives as occurrences; the app's copy is
// this variable, not a widget read.
var draft = ""
var nextKey = 0

var status: KayaSignal!
var history: KayaSignal!
var field: KayaWidget!
var todos: KayaRecordCollection<Todo>!

/// What the history label says a step was. A typing episode has no
/// authored name and kaya invents none ("Undo Typing" is an Apple
/// convention, not a scene string — docs/undo-plan.md D8), so the empty
/// label is the app's to spell.
func what(_ label: String) -> String {
    label.isEmpty ? "typing" : label
}

app.build { tx in
    // THE GESTURE LAYER, one tier deeper: an app declares the two items
    // and writes nothing else. They act on the focused widget, lower to
    // the platform's own command where it has one, and work out their own
    // enablement from what is focused and what the ledger holds.
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Undo", role: KayaAppTx.roleUndo),
            tx.item("Redo", role: KayaAppTx.roleRedo),
        ])
    // Per window, and PERSISTENT: a history is walked as often as the
    // user likes. The binding has already reconciled its collection
    // mirror from this payload before the handler runs, which is why the
    // count below answers about the restored state.
    tx.window(
        title: "undo",
        onUndone: { tx, label, delta in
            // THE DELTA IS THE ONLY NOTIFICATION for that text: restoring
            // an episode is a programmatic write, and a programmatic
            // write never echoes, so an app that folds text_changed into
            // its own model — which is every app, the field being
            // uncontrolled — would go stale on exactly this step if the
            // payload did not carry it (D5).
            if let restored = delta.texts.last { draft = restored.text }
            let total = todos.items(tx).count
            tx.write(history, .str("undid \(what(label)), \(total) total"))
        },
        onRedone: { tx, label, delta in
            if let restored = delta.texts.last { draft = restored.text }
            let total = todos.items(tx).count
            tx.write(history, .str("redid \(what(label)), \(total) total"))
        },
        menus: [edit])

    status = tx.signal(.str("no todos"))
    history = tx.signal(.str("history empty"))
    todos = todoCollection(tx)

    let root = tx.column {
        tx.setA11yId(tx.label(bind: status), "status")  // label#0
        tx.setA11yId(tx.label(bind: history), "history")  // label#1
        field = tx.entry { _, text in draft = text }  // entry#0
        tx.setA11yId(field, "draft")
        tx.button("add") { tx in  // button#0
            if draft.isEmpty {
                let total = todos.items(tx).count
                tx.write(status, .str("nothing to add, \(total) total"))
                return
            }
            nextKey += 1
            // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name is
            // what the step is called; everything in this batch is what
            // it did.
            tx.undoable("add \(draft)")
            todos.insert(tx, .str("t\(nextKey)"), Todo(title: draft))
            let total = todos.items(tx).count
            tx.write(status, .str("added \(draft), \(total) total"))
            // A PURE EFFECT rides along and is simply not restored: undo
            // restores state, not where you were looking (A2).
            tx.focus(field)
            // FINISHING THE FORM IS NOT PART OF THE STEP. Its own
            // transaction — a posted body runs in one of its own, right
            // after this one — so undoing the add does not put the draft
            // back beside a todo that is gone, and `clear` inside a group
            // would be refused anyway. The field empties on screen and
            // reports text_changed("") through its normal edit path, so
            // the fold above empties the draft.
            app.post { tx in tx.clear(field) }
        }
        // A group at its smallest: one signal write, which is the
        // undoable set's whole vocabulary on the reactive side.
        tx.button("star") { tx in  // button#1
            tx.write(status, .str("starred"))
            // NAMED AFTER THE FACT, which is the ordinary way a handler
            // works: it builds first and knows what the step was
            // afterwards. The marker still rides at the HEAD of the
            // batch — that is the wire's rule and the binding's job,
            // and this call site is what proves the binding does it:
            // an implementation that appended instead would put the
            // marker second and the core would refuse the whole
            // transaction, naming the position.
            tx.undoable("star")
        }
        // THE SCENE'S WAY BACK TO THE FIELD. `star` does not move the
        // cursor on its own — an app that reaches for focus after every
        // action is deciding where the user is looking — so the scene
        // says so itself, and the routing question ("what is focused?")
        // stays visible in the script rather than hidden in a handler.
        tx.button("focus") { tx in tx.focus(field) }  // button#2
        for row in todos.rows {
            row.row {
                row.label(row.title)
            }
        }
    }
    // THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
    // holding focus when it does — and focus is the routing question's
    // other half.
    tx.focus(field)
    tx.mount(root)
}

app.run()
