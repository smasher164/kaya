// The entry scene, Swift port — guests/rust/entry.rs,
// tools/scenes/entry.steps.

import Foundation

let app = KayaApp()

let (status, field, add, todos) = app.build {
    tx -> (KayaSignal, KayaWidget, KayaWidget, KayaCollection) in
    let status = tx.signal(.str("no todos"))
    let todos = tx.collection()

    let (root, field, add) = tx.column { root -> (KayaWidget, KayaWidget, KayaWidget) in
        let field = tx.entry()  // entry#0
        let add = tx.button("add")  // button#0
        tx.label(bind: status)  // label#0
        tx.each(todos) { t in
            t.label(KayaField<String>(index: 0))
        }
        return (root, field, add)
    }
    tx.mount(root)
    return (status, field, add, todos)
}

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
