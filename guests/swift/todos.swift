// The todos scene, Swift port — guests/rust/todos.rs,
// tools/scenes/todos.steps.

import Foundation

struct Todo: KayaGen {
    var title: String
    var done: Bool
}

let app = KayaApp()

var draft = ""

app.build { tx in
    // The two items are the whole undo surface an app declares
    // (docs/undo-plan.md D1-D6).
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Undo", role: KayaAppTx.roleUndo),
            tx.item("Redo", role: KayaAppTx.roleRedo),
        ])
    // NO onUndone AND NO onRedone: this scene's whole state is the collection
    // and the signal derived from it, both of which the core restores.
    tx.window(title: "todos", menus: [edit])
    let todos = todoCollection(tx)
    let itemsLeft = todos.derive(tx) { items in
        let n = items.filter { !$0.value.done }.count
        return .str(n == 1 ? "1 item left" : "\(n) items left")
    }

    let root = tx.column {
        let field = tx.entry { _, text in draft = text }
        tx.button("Add") { tx in
            if draft.isEmpty { return }
            // The derive's write is in THIS batch, so the step's inverse
            // carries "0 items left".
            tx.undoable("add \(draft)")
            // The binding mints the key (docs/fresh-key-plan.md).
            todos.insertFresh(tx, Todo(title: draft, done: false))
            // `clear` inside a group is refused at apply (docs/undo-plan.md D4).
            app.post { tx in
                tx.clear(field)
                tx.focus(field)
            }
        }
        tx.label(bind: itemsLeft)
        for row in todos.rows {
            row.row {
                row.checkbox(row.done) { tx, keys, checked in
                    todos.patch(tx, keys[0]).set(\.done, checked)
                }
                row.label(row.title)
            }
        }
    }
    tx.mount(root)
}

app.run()
