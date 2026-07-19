// The entry scene from Swift: the uncontrolled contract end to end.
// The field owns its text and reports each edit through onChange; the
// app folds those into a plain variable (draft) — its own model, per
// doctrine. The add button inserts the draft and answers with the count
// read from the collection model, then clears and refocuses the field —
// one-shot commands riding the insert's transaction; the clear's own
// text_changed("") re-enters through the fold and empties the draft,
// so a second add finds nothing to add.

import Foundation

let app = KayaApp()

let (status, field, add, todos) = app.build {
    tx -> (KayaSignal, KayaWidget, KayaWidget, KayaCollection) in
    let status = tx.signal(.str("no todos"))

    let column = tx.widget(UInt32(KAYA_KIND_COLUMN))
    let field = tx.widget(UInt32(KAYA_KIND_ENTRY))
    let add = tx.widget(UInt32(KAYA_KIND_BUTTON))
    tx.setText(add, "add")
    let statusLabel = tx.widget(UInt32(KAYA_KIND_LABEL))
    tx.bindText(statusLabel, status)

    let todos = tx.collection()
    let (todoList, _) = tx.forEach(todos) { t in
        let label = t.widget(UInt32(KAYA_KIND_LABEL))
        t.bindTextElement(label)
    }

    tx.addChild(column, field)
    tx.addChild(column, add)
    tx.addChild(column, statusLabel)
    tx.addChild(column, todoList)
    tx.mount(column)
    return (status, field, add, todos)
}

// The fold: widget-owned state arrives as occurrences; the app's copy
// is this variable, not a widget read.
var draft = ""
var nextKey = 0
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
    nextKey += 1
    tx.insert(todos, .str("t\(nextKey)"), .str(draft))
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
