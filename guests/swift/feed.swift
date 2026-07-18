// The feed scene from Swift: sum-typed elements, end to end. The enum
// is the sum, its cases the constructors — one prototype per case
// derives the schemas via Mirror, and init(variant:values:) is the one
// hand-written member, per the record precedent. The template takes a
// product of arms (checked complete at declaration, and again by the
// scene), and handlers eliminate with `if case` — a refinement the
// witnessed updateField checks rather than trusts, so a stale
// occurrence folds into nothing.

import Foundation

enum Post: KayaSumElement {
    case note(text: String)
    case todo(title: String, done: Bool)

    static let prototypes: [Post] = [
        .note(text: ""),
        .todo(title: "", done: false),
    ]

    init(variant: UInt32, values: [KayaValue]) {
        switch variant {
        case 0:
            guard case .str(let text) = values[0] else {
                preconditionFailure("kaya: note fields out of order")
            }
            self = .note(text: text)
        case 1:
            guard case .str(let title) = values[0], case .bool(let done) = values[1] else {
                preconditionFailure("kaya: todo fields out of order")
            }
            self = .todo(title: title, done: done)
        default:
            preconditionFailure("kaya: Post has no variant \(variant)")
        }
    }
}

let app = KayaApp()

app.build { tx in
    let feed = tx.sumCollection(of: Post.self)
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
    let list = tx.eachSum(feed, arms: [
        feed.arm(.note(text: "")) { t, note in
            _ = note.label(t, "text")
        },
        feed.arm(.todo(title: "", done: false)) { t, todo in
            _ = t.row {
                todo.checkbox(t, "done") { tx, keys, checked in
                    // `if case` is the refinement; updateField
                    // witnesses it. A stale occurrence folds into
                    // nothing.
                    if case .todo = feed.get(tx, keys[0]) {
                        feed.updateField(
                            tx, keys[0], of: .todo(title: "", done: false), "done",
                            .bool(checked))
                    }
                }
                todo.label(t, "title")
            }
        },
    ])
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
