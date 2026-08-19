// The entry scene from Swift: the uncontrolled contract end to end. The
// field owns its text and reports each edit through onChange; the app
// folds those into a plain variable. The clear's own text_changed("")
// re-enters through the fold and empties the draft.
//
// WHAT THIS SCENE DOCUMENTS IS HOW OCCURRENCES REACH AN APP: its two
// handlers are registered CENTRALLY, after the build, against the
// handles the build body handed back — the tier underneath the
// onChange:/onClick: arguments todos.swift and undo.swift pass.

import Foundation

let app = KayaApp()

let (status, field, add, todos) = app.build {
    tx -> (KayaSignal, KayaWidget, KayaWidget, KayaCollection) in
    let status = tx.signal(.str("no todos"))
    let todos = tx.collection()

    // The two handles the central registrations below need. A widget
    // parents at CREATION, so both are built inside the container body
    // and ride out through these (docs/traps.md, result builders).
    var field: KayaWidget! = nil
    var add: KayaWidget! = nil

    let root = tx.column {
        field = tx.entry()  // entry#0
        add = tx.button("add")  // button#0
        tx.label(bind: status)  // label#0
        // The template: one stamped label bound to the element itself. A
        // scalar collection's entry IS its one wire field, so the row's
        // label addresses field 0.
        tx.each(todos) { t in
            _ = t.label(KayaField<String>(index: 0))
        }
    }
    tx.mount(root)
    return (status, field, add, todos)
}

// The fold: widget-owned state arrives as occurrences.
var draft = ""
app.onChange(field) { _, text in
    draft = text
}
app.onClick(add) { tx in
    if draft.isEmpty {
        tx.write(status, .str("nothing to add, \(tx.count(todos)) total"))
        return
    }
    tx.insertFresh(todos, .str(draft))
    let total = tx.count(todos)
    tx.write(status, .str("added \(draft), \(total) total"))
    tx.clear(field)
    tx.focus(field)
}

app.run()
