// The todos scene from Swift, on the construction sugar: the struct is
// the schema — kaya-swift-gen reads this declaration and generates
// todos+Kaya.swift (the KayaRecord conformance, typed field tokens and
// the collection factory).
//
// AND THE APP NAMES NO TODO: a title and a done flag identify nothing,
// so the key comes from insertFresh (docs/fresh-key-plan.md). The row's
// checkbox carries that key back out through the stamped path and into
// patch, which is all this scene asks of a key.
//
// AND THE ITEMS-LEFT LABEL COMES BACK FROM AN UNDO WITH NOBODY PUTTING
// IT BACK: the derive's write rides the add's own named batch, so the
// core banks the label in both directions. That is why this file
// registers no onUndone, and why a binding that recomputed the derive
// while absorbing the payload would write a value the ledger never
// banked (KayaApp.absorbUndo says so from the other side).

import Foundation

struct Todo: KayaGen {
    var title: String
    var done: Bool
}

let app = KayaApp()

// The fold: widget-owned state arrives as occurrences.
var draft = ""

app.build { tx in
    // THE GESTURE LAYER, and these two items are the whole of it: they
    // act on what is focused and work out their own enablement
    // (docs/undo-plan.md D1-D6).
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Undo", role: KayaAppTx.roleUndo),
            tx.item("Redo", role: KayaAppTx.roleRedo),
        ])
    // The menubar rides the window construct because the LEDGER is per
    // window. NO onUndone AND NO onRedone: this scene's whole state is
    // the collection and the signal derived from it, both of which the
    // core restores on its own.
    tx.window(title: "todos", menus: [edit])
    let todos = todoCollection(tx)
    // A derived signal: the binding recomputes it after every mutation.
    let itemsLeft = todos.derive(tx) { items in
        let n = items.filter { !$0.value.done }.count
        return .str(n == 1 ? "1 item left" : "\(n) items left")
    }

    let root = tx.column {
        let field = tx.entry { _, text in draft = text }
        tx.button("Add") { tx in
            if draft.isEmpty { return }
            // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The derive's
            // write is in THIS batch, so the step's inverse carries
            // "0 items left" and its forward carries "1 item left".
            tx.undoable("add \(draft)")
            // NO KEY, AND NO COUNTER TO GET WRONG: the binding mints the
            // name and hands it back; @discardableResult permits the drop.
            todos.insertFresh(tx, Todo(title: draft, done: false))
            // FINISHING THE FORM IS NOT PART OF THE STEP, so it takes a
            // transaction of its own; `clear` inside a group would be
            // refused at apply anyway (docs/undo-plan.md D4). The field
            // reports text_changed("") through its normal edit path.
            app.post { tx in
                tx.clear(field)
                tx.focus(field)
            }
        }
        tx.label(bind: itemsLeft)
        // The tracing tier: the for statement IS the For — the body runs
        // once, and stamping is the core's replay.
        for row in todos.rows {
            row.row {
                row.checkbox(row.done) { tx, keys, checked in
                    // One field's delta: the title never travels.
                    todos.patch(tx, keys[0]).set(\.done, checked)
                }
                row.label(row.title)
            }
        }
    }
    tx.mount(root)
}

app.run()
