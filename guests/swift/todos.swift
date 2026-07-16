// The todos scene from Swift, on the construction sugar: the struct is
// the schema (Mirror walks a prototype), constructors carry their
// props and handlers, and result-builder containers make the build
// closure the scene's shape. The sugar lowers eagerly to the same
// records as the explicit floor — milestone2.swift keeps that style on
// purpose.

import Foundation

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

let app = KayaApp()

// The fold: widget-owned state arrives as occurrences; the app's copy
// is this variable, not a widget read.
var draft = ""
var nextKey = 0

app.build { tx in
    let todos = tx.collection(of: Todo.self)
    // The items-left label is a derived signal: the binding recomputes
    // it from the collection after every mutation, so no handler
    // mentions it.
    let itemsLeft = todos.derive(tx) { items in
        let n = items.filter { !$0.value.done }.count
        return .str(n == 1 ? "1 item left" : "\(n) items left")
    }

    let root = tx.column {
        tx.entry { _, text in draft = text }
        tx.button("Add") { tx in
            nextKey += 1
            todos.insert(tx, .str("t\(nextKey)"), Todo(title: draft, done: false))
        }
        tx.label(bind: itemsLeft)
        tx.each(todos.collection) { t in
            _ = t.row {
                todos.checkbox(t, \.done) { tx, keys, checked in
                    // One field's delta: the title never travels; the
                    // derived signal updates itself.
                    todos.patch(tx, keys[0]).set(\.done, checked)
                }
                todos.label(t, \.title)
            }
        }
    }
    tx.mount(root)
}

app.run()
