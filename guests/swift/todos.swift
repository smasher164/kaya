// The todos scene from Swift: records and field projection. The struct
// is the schema — Mirror walks a prototype once at declaration — the
// template binds each field to its own widget through typed field
// tokens, and toggling a row sends one field's delta through
// updateField: the title never travels.

import Foundation

// The record is the schema; init(values:) is the one hand-written
// member (Mirror cannot construct), everything else derives.
struct Todo: KayaRecord {
    var title: String
    var done: Bool

    static let prototype = Todo(title: "", done: false)

    init(title: String, done: Bool) {
        self.title = title
        self.done = done
    }

    init(values: [KayaValue]) {
        guard case .str(let title) = values[0], case .bool(let done) = values[1] else {
            preconditionFailure("kaya: Todo fields out of order")
        }
        self.init(title: title, done: done)
    }
}

// The field tokens, checked against the struct at startup.
let fieldTitle = Todo.field("title", String.self)
let fieldDone = Todo.field("done", Bool.self)

let app = KayaApp()

func itemsLeftText(_ tx: KayaAppTx, _ todos: KayaRecordCollection<Todo>) -> String {
    let n = todos.items(tx).filter { !$0.value.done }.count
    return n == 1 ? "1 item left" : "\(n) items left"
}

let (itemsLeft, field, add, todos, check) = app.build {
    tx -> (KayaSignal, KayaWidget, KayaWidget, KayaRecordCollection<Todo>, KayaNodeHandle) in
    let itemsLeft = tx.signal(.str("0 items left"))

    let column = tx.widget(UInt32(KAYA_KIND_COLUMN))
    let field = tx.widget(UInt32(KAYA_KIND_ENTRY))
    let add = tx.widget(UInt32(KAYA_KIND_BUTTON))
    tx.setText(add, "Add")
    let status = tx.widget(UInt32(KAYA_KIND_LABEL))
    tx.bindText(status, itemsLeft)

    let todos = tx.collection(of: Todo.self)
    let (todoList, check) = tx.forEach(todos.collection) { t -> KayaNodeHandle in
        let row = t.widget(UInt32(KAYA_KIND_ROW))
        let check = t.widget(UInt32(KAYA_KIND_CHECKBOX))
        t.bindCheckedField(check, fieldDone)
        let title = t.widget(UInt32(KAYA_KIND_LABEL))
        t.bindTextField(title, fieldTitle)
        t.addChild(row, check)
        t.addChild(row, title)
        return check
    }

    tx.addChild(column, field)
    tx.addChild(column, add)
    tx.addChild(column, status)
    tx.addChild(column, todoList)
    tx.mount(column)
    return (itemsLeft, field, add, todos, check)
}

// The fold: widget-owned state arrives as occurrences; the app's copy
// is this variable, not a widget read.
var draft = ""
var nextKey = 0
app.onChange(field) { _, text in
    draft = text
}
app.onClick(add) { tx in
    nextKey += 1
    todos.insert(tx, .str("t\(nextKey)"), Todo(title: draft, done: false))
    tx.write(itemsLeft, .str(itemsLeftText(tx, todos)))
}
app.onToggle(check) { tx, keys, checked in
    // One field's delta: the title never travels.
    todos.updateField(tx, keys[0], fieldDone, checked)
    tx.write(itemsLeft, .str(itemsLeftText(tx, todos)))
}

app.run()
