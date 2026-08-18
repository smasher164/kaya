// The feed scene from Swift: sum-typed elements, end to end. The enum is
// the sum; kaya-swift-gen reads this declaration and generates
// feed+Kaya.swift (prototypes, init(variant:values:), typed field
// tokens, the collection factory, and the compile-total postEachSum
// eliminator). Handlers eliminate with `if case`, and the witnessed
// updateField checks that refinement rather than trusting it.

import Foundation

enum Post: KayaGen {
    case note(text: String)
    case todo(title: String, done: Bool)
}

let app = KayaApp()

app.build { tx in
    let feed = postCollection(tx)
    let doneCount = feed.derive(tx) { items in
        let n = items.filter { entry in
            if case .todo(_, let done) = entry.value { return done }
            return false
        }.count
        return .str("\(n) done")
    }

    // Every child is declared WHERE IT STANDS: a widget parents at
    // CREATION, and a bare expression never reaches buildExpression
    // (docs/traps.md, result builders).
    let root = tx.row {
    tx.button("promote") { tx in
        for entry in feed.items(tx) {
            if case .note(let text) = entry.value {
                feed.update(tx, entry.key, .todo(title: text, done: true))
                break
            }
        }
    }
    tx.label(bind: doneCount)
    _ = postEachSum(
        tx, feed,
        note: { note in
            _ = note.label(note.text)
        },
        todo: { todo in
            _ = todo.row {
                todo.checkbox(todo.done) { tx, keys, checked in
                    // Optional chaining re-eliminates at write time: a
                    // stale occurrence folds into nil.
                    postAsTodo(tx, feed, keys[0])?.done(checked)
                }
                todo.label(todo.title)
            }
        })
    }
    tx.mount(root)
    feed.insert(tx, .str("a"), .note(text: "jot one"))
    feed.insert(tx, .str("b"), .todo(title: "buy milk", done: false))
    feed.insert(tx, .str("c"), .note(text: "jot two"))
}

app.run()
