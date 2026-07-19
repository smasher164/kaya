// The todos scene from Swift, on the construction sugar: the struct is
// the schema — kaya-swift-gen reads this declaration and generates
// todos+Kaya.swift (the KayaRecord conformance, typed field tokens,
// and the collection factory) — constructors carry their props and
// handlers, and result-builder containers make the build closure the
// scene's shape. The sugar lowers eagerly to the same records as the
// explicit floor — the C guests keep that style on purpose.

import Foundation

struct Todo: KayaGen {
    var title: String
    var done: Bool
}

let app = KayaApp()

// The fold: widget-owned state arrives as occurrences; the app's copy
// is this variable, not a widget read.
var draft = ""
var nextKey = 0

app.build { tx in
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
            nextKey += 1
            todos.insert(tx, .str("t\(nextKey)"), Todo(title: draft, done: false))
            // Finish the form: the field empties on screen and reports
            // text_changed("") through its normal edit path (the fold
            // empties the draft), and the cursor lands back in it.
            tx.clear(field)
            tx.focus(field)
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
