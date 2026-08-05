// The entry scene from Swift: the uncontrolled contract end to end.
// The field owns its text and reports each edit through onChange; the
// app folds those into a plain variable (draft) — its own model, per
// doctrine. The add button inserts the draft and answers with the count
// read from the collection model, then clears and refocuses the field —
// one-shot commands riding the insert's transaction; the clear's own
// text_changed("") re-enters through the fold and empties the draft,
// so a second add finds nothing to add.
//
// WHAT THIS SCENE DOCUMENTS IS HOW OCCURRENCES REACH AN APP, and only
// that (DESIGN.md, the scope ratified 2026-08-05). The two handlers are
// registered CENTRALLY, after the build, against the handles the build
// body handed back — the tier underneath the onChange:/onClick:
// arguments todos.swift and undo.swift pass to their constructors. Both
// spellings put the same closure in the same table, since a constructor
// that takes a handler calls app.onChange/app.onClick itself; this file
// is where the plain one is written down, and it is also why these two
// widgets are the only ones that leave the container body. Construction
// is the ordinary sugar every example that is not a C guest uses.
//
// AND THE APP NAMES NO TODO. A draft is a line of text and nothing else
// — it has no identity of its own — so the key comes from insertFresh:
// the binding mints one per collection instance and hands it back
// (docs/fresh-key-plan.md). This file used to carry nextKey, a counter
// beside the collection whose safety rested on never rewinding. Nothing
// here has a use for the minted name, so the call is made for effect —
// which is what @discardableResult permits — and an app that does need
// it (selecting the new row, say) takes it from here rather than
// inventing a second name for the same datum.

import Foundation

let app = KayaApp()

let (status, field, add, todos) = app.build {
    tx -> (KayaSignal, KayaWidget, KayaWidget, KayaCollection) in
    let status = tx.signal(.str("no todos"))
    let todos = tx.collection()

    // The two handles the central registrations below need. A widget
    // parents into its container AT CREATION, so both are built inside
    // the container body like every other child and ride out through
    // these — never declared outside it and named within, which parents
    // nothing.
    var field: KayaWidget! = nil
    var add: KayaWidget! = nil

    let root = tx.column {
        // No onChange:/onClick: arguments, on purpose: this scene
        // registers centrally, so the sugar it takes is the
        // construction half alone.
        field = tx.entry()  // entry#0
        add = tx.button("add")  // button#0
        tx.label(bind: status)  // label#0
        // The template: one stamped label per entry, bound to the
        // element itself. A scalar collection's entry IS its one wire
        // field, so the row's label addresses field 0 — the token is
        // the address, and the constructor is the same `label` the
        // live zone uses.
        tx.each(todos) { t in
            _ = t.label(KayaField<String>(index: 0))
        }
    }
    tx.mount(root)
    return (status, field, add, todos)
}

// The fold: widget-owned state arrives as occurrences; the app's copy
// is this variable, not a widget read.
var draft = ""
app.onChange(field) { _, text in
    draft = text
}
app.onClick(add) { tx in
    // The empty-draft guard every real form has — and the scene's
    // proof that clear emptied the draft through the occurrence fold,
    // not a side assignment.
    if draft.isEmpty {
        tx.write(status, .str("nothing to add, \(tx.count(todos)) total"))
        return
    }
    tx.insertFresh(todos, .str(draft))
    let total = tx.count(todos)
    tx.write(status, .str("added \(draft), \(total) total"))
    // Finish the form: drop the field's content and put the cursor
    // back, atomically with the insert. The field answers with
    // text_changed("") through its normal edit path, and the fold
    // above empties the draft.
    tx.clear(field)
    tx.focus(field)
}

app.run()
