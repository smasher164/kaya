// The feed scene from Swift: sum-typed elements, end to end. The enum
// is the sum, its cases the constructors — kaya-swift-gen reads this
// declaration and generates feed+Kaya.swift: the prototypes and
// init(variant:values:), typed field tokens, the collection factory,
// and the compile-total postEachSum eliminator (one required labeled
// parameter per constructor). Handlers eliminate with `if case` — a
// refinement the witnessed updateField checks rather than trusts, so
// a stale occurrence folds into nothing.

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

    let promote = tx.button("promote") { tx in
        // The first note, promoted to a finished todo: the model is
        // asked which entry is a Note, and the update's new
        // constructor restamps that key's copy in place.
        for entry in feed.items(tx) {
            if case .note(let text) = entry.value {
                feed.update(tx, entry.key, .todo(title: text, done: true))
                break
            }
        }
    }
    let status = tx.label(bind: doneCount)
    // The generated eliminator: one required labeled parameter per
    // constructor, so a missing arm is a missing argument — a compile
    // error. The arms' tokens are typed; no label strings.
    let list = postEachSum(
        tx, feed,
        note: { note in
            _ = note.label(note.text)
        },
        todo: { todo in
            _ = todo.row {
                todo.checkbox(todo.done) { tx, keys, checked in
                    // The generated refined patch: optional chaining
                    // re-eliminates at write time (a stale occurrence
                    // folds into nil), and the update stays witnessed
                    // underneath.
                    postAsTodo(tx, feed, keys[0])?.done(checked)
                }
                todo.label(todo.title)
            }
        })
    let root = tx.row {
        promote
        status
        list
    }
    tx.mount(root)
    feed.insert(tx, .str("a"), .note(text: "jot one"))
    feed.insert(tx, .str("b"), .todo(title: "buy milk", done: false))
    feed.insert(tx, .str("c"), .note(text: "jot two"))
}

app.run()
