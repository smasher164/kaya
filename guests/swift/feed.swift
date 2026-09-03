// The feed scene, Swift port — guests/rust/feed.rs, tools/scenes/feed.steps.

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

    // A bare expression never reaches buildExpression, so every child is
    // declared WHERE IT STANDS (docs/traps.md, result builders).
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
                    // Optional chaining re-eliminates at write time: a stale
                    // occurrence folds into nil.
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
