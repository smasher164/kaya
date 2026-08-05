// The todos scene from Swift, on the construction sugar: the struct is
// the schema — kaya-swift-gen reads this declaration and generates
// todos+Kaya.swift (the KayaRecord conformance, typed field tokens,
// and the collection factory) — constructors carry their props and
// handlers, and result-builder containers make the build closure the
// scene's shape. The sugar lowers eagerly to the same records as the
// explicit floor — the C guests keep that style on purpose.
//
// AND THE APP NAMES NO TODO. A todo here is a title and a done flag,
// and neither of them identifies it, so the key comes from insertFresh:
// the binding mints one per collection instance and hands it back
// (docs/fresh-key-plan.md). The row's checkbox carries that key back
// out through the stamped path and straight into patch, which is the
// whole of what this scene asks of a key — the app never reads it,
// formats it or compares it, and so has no reason to author it.
//
// AND THE ITEMS-LEFT LABEL COMES BACK FROM AN UNDO WITH NOBODY PUTTING
// IT BACK. The add is a named step (`tx.undoable`) and the derive's
// write is in that same batch — insertFresh recomputes and pushes an
// ordinary signal write into the transaction that caused it — so the
// core banks the label in both directions of the step and hands it back
// together with the todo it counts. Which is why this file registers no
// onUndone: there is nothing left for a handler to put right, and a
// binding that recomputed the derive while absorbing the payload would
// be writing a value the ledger never banked (KayaApp.absorbUndo says
// so from the other side).

import Foundation

struct Todo: KayaGen {
    var title: String
    var done: Bool
}

let app = KayaApp()

// The fold: widget-owned state arrives as occurrences; the app's copy
// is this variable, not a widget read.
var draft = ""

app.build { tx in
    // THE GESTURE LAYER, and these two items are the whole of it: the
    // app declares them and writes nothing else. They act on what is
    // focused, lower to the platform's own command where it has one, and
    // work out their own enablement from what the ledger holds
    // (docs/undo-plan.md D1-D6).
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Undo", role: KayaAppTx.roleUndo),
            tx.item("Redo", role: KayaAppTx.roleRedo),
        ])
    // The menubar rides the window construct because the LEDGER is per
    // window. NO onUndone AND NO onRedone, deliberately: this scene's
    // whole state is the collection and the signal derived from it, both
    // of which the core restores on its own, so a history handler here
    // would have nothing to say.
    tx.window(title: "todos", menus: [edit])
    let todos = todoCollection(tx)
    // The items-left label is a derived signal: the binding recomputes
    // it from the collection after every mutation, so no handler
    // mentions it.
    let itemsLeft = todos.derive(tx) { items in
        let n = items.filter { !$0.value.done }.count
        return .str(n == 1 ? "1 item left" : "\(n) items left")
    }

    let root = tx.column {
        let field = tx.entry { _, text in draft = text }
        tx.button("Add") { tx in
            if draft.isEmpty { return }
            // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. What brings
            // the items-left label back with the todo is that the
            // derive's write is in THIS batch: insertFresh recomputes
            // and pushes an ordinary signal write, and a named
            // transaction banks every signal it dirtied in both
            // directions. So the step's inverse carries "0 items left"
            // and its forward carries "1 item left", and the label
            // travels by the same mechanism as the entry it counts.
            tx.undoable("add \(draft)")
            // NO KEY, AND NO COUNTER TO GET WRONG: the binding mints the
            // name and hands it back. This app has no use for the
            // returned key — a todo is looked up by nothing, and the
            // checkbox's own path names its row — so the call is made
            // for effect, which @discardableResult is what permits.
            todos.insertFresh(tx, Todo(title: draft, done: false))
            // FINISHING THE FORM IS NOT PART OF THE STEP, so it takes a
            // transaction of its own — a posted body runs in one, right
            // after this one. Undoing the add must not put "buy milk"
            // back in the field beside a todo that is gone, and `clear`
            // inside a group would be refused at apply anyway (D4),
            // because it destroys widget-owned text the core never held.
            // The field empties on screen and reports text_changed("")
            // through its normal edit path (the fold empties the draft),
            // and the cursor lands back in it.
            app.post { tx in
                tx.clear(field)
                tx.focus(field)
            }
        }
        tx.label(bind: itemsLeft)
        // The tracing tier: the for statement IS the For — the body
        // runs once over the generated row surface (exact-index
        // tokens, no key paths at bind time), and stamping is the
        // core's replay.
        for row in todos.rows {
            row.row {
                row.checkbox(row.done) { tx, keys, checked in
                    // One field's delta: the title never travels; the
                    // derived signal updates itself.
                    todos.patch(tx, keys[0]).set(\.done, checked)
                }
                row.label(row.title)
            }
        }
    }
    tx.mount(root)
}

app.run()
