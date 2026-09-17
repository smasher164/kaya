// The app-owned undo scene, Swift port — guests/rust/ownundo.rs,
// tools/scenes/ownundo.steps (docs/rich-text-plan.md R6, §14).

import Foundation

let app = KayaApp()

// The app's own history: the document before each user edit, and the
// documents an undo took away. The binding's mirror is the document AFTER
// the edit it just delivered.
var undoStack: [KayaDocument] = []
var redoStack: [KayaDocument] = []
var current = KayaDocument("")

var status: KayaSignal!
var native: KayaWidget!
var owned: KayaWidget!

func publish(_ t: KayaAppTx) {
    t.write(status, .str("undo \(undoStack.count) redo \(redoStack.count)"))
    t.canUndo(owned, !undoStack.isEmpty)
    t.canRedo(owned, !redoStack.isEmpty)
}

app.build { tx in
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Undo", role: .undo) { t in
                guard let before = undoStack.popLast() else { return }
                redoStack.append(current)
                current = before
                t.setDocument(owned, before)
                publish(t)
            },
            tx.item("Redo", role: .redo) { t in
                guard let after = redoStack.popLast() else { return }
                undoStack.append(current)
                current = after
                t.setDocument(owned, after)
                publish(t)
            },
        ])
    tx.window(title: "ownundo", menus: [edit])
    status = tx.signal(.str("undo 0 redo 0"))

    let root = tx.column {
        let label = tx.label(bind: status)  // label#0
        tx.setA11yId(label, "status")
        native = tx.textarea(rich: true)  // textarea#0
        tx.setA11yId(native, "native")
        tx.setA11yLabel(native, "Native")
        owned = tx.textarea(  // textarea#1
            rich: true, ownUndo: true,
            onEdit: { t, _ in
                undoStack.append(current)
                current = app.document(owned)
                redoStack.removeAll()
                publish(t)
            })
        tx.setA11yId(owned, "owned")
        tx.setA11yLabel(owned, "Owned")
        tx.row {
            tx.button("focus native") { t in t.focus(native) }  // button#0
            tx.button("focus owned") { t in t.focus(owned) }  // button#1
        }
    }
    tx.mount(root)
}

app.run()
