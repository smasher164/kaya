// The undo scene, Swift port — guests/rust/undo.rs, tools/scenes/undo.steps.

import Foundation

struct Todo: KayaGen {
    var title: String
}

let app = KayaApp()

// Two mirrors, because the payload's path tells a row's field from the draft.
var draft = ""
var rowNotes: [Int64: String] = [:]

var status: KayaSignal!
var history: KayaSignal!
var keys: KayaSignal!
var notes: KayaSignal!
var field: KayaWidget!
var todos: KayaRecordCollection<Todo>!

/// kaya invents no name for a typing episode (docs/undo-plan.md D8).
func what(_ label: String) -> String {
    label.isEmpty ? "typing" : label
}

/// Every key the collection holds, in order — THE ONLY PART OF AN UNDO A
/// COUNT CANNOT SEE (D5).
func keyList(_ tx: KayaAppTx) -> String {
    let ks = todos.items(tx).map { entry -> String in
        // The minter's keys are I64; the only place this app reads one.
        guard case .i64(let n) = entry.key else {
            preconditionFailure("kaya: a minted key is I64")
        }
        return String(n)
    }
    return ks.isEmpty ? "no keys" : "keys \(ks.joined(separator: ","))"
}

/// The row a stamped copy's occurrence names.
func rowKey(_ path: [KayaValue]) -> Int64 {
    guard case .i64(let n) = path[0] else {
        preconditionFailure("kaya: a minted key is I64")
    }
    return n
}

/// Every note the app holds, by key. Sorted, because a Dictionary has no
/// order and the script compares bytes.
func noteList() -> String {
    if rowNotes.isEmpty {
        return "no notes"
    }
    let rendered = rowNotes.keys.sorted().map { key in "\(key)=\(rowNotes[key]!)" }
    return "notes \(rendered.joined(separator: ","))"
}

/// The empty path is the draft, a path names a row, AN EMPTY NOTE IS NO NOTE.
func foldTexts(_ texts: [KayaUndoText]) {
    for restored in texts {
        if restored.path.isEmpty {
            draft = restored.text
        } else if restored.text.isEmpty {
            rowNotes.removeValue(forKey: rowKey(restored.path))
        } else {
            rowNotes[rowKey(restored.path)] = restored.text
        }
    }
}

app.build { tx in
    // The two items are the whole undo surface an app declares.
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Undo", role: KayaAppTx.roleUndo),
            tx.item("Redo", role: KayaAppTx.roleRedo),
        ])
    // The binding has reconciled its collection mirror before this runs.
    tx.window(
        title: "undo",
        onUndone: { tx, label, delta in
            // THE DELTA IS THE ONLY NOTIFICATION for that text: an undo
            // is a programmatic write and never echoes (D5). The run is
            // walked whole, because an entry NAMES the field it restores.
            foldTexts(delta.texts)
            let total = todos.items(tx).count
            tx.write(history, .str("undid \(what(label)), \(total) total"))
            // ONE TRANSACTION with the label above: the script reads that
            // label first.
            tx.write(keys, .str(keyList(tx)))
            tx.write(notes, .str(noteList()))
        },
        onRedone: { tx, label, delta in
            foldTexts(delta.texts)
            let total = todos.items(tx).count
            tx.write(history, .str("redid \(what(label)), \(total) total"))
            tx.write(keys, .str(keyList(tx)))
            tx.write(notes, .str(noteList()))
        },
        menus: [edit])

    status = tx.signal(.str("no todos"))
    history = tx.signal(.str("history empty"))
    keys = tx.signal(.str("no keys"))
    notes = tx.signal(.str("no notes"))
    todos = todoCollection(tx)

    let root = tx.column {
        tx.setA11yId(tx.label(bind: status), "status")  // label#0
        tx.setA11yId(tx.label(bind: history), "history")  // label#1
        tx.setA11yId(tx.label(bind: keys), "keys")  // label#2
        tx.setA11yId(tx.label(bind: notes), "notes")  // label#3
        field = tx.entry { _, text in draft = text }  // entry#0
        tx.setA11yId(field, "draft")
        tx.button("add") { tx in  // button#0
            if draft.isEmpty {
                let total = todos.items(tx).count
                tx.write(status, .str("nothing to add, \(total) total"))
                return
            }
            tx.undoable("add \(draft)")
            // The binding mints the key (docs/fresh-key-plan.md).
            todos.insertFresh(tx, Todo(title: draft))
            let total = todos.items(tx).count
            tx.write(status, .str("added \(draft), \(total) total"))
            tx.write(keys, .str(keyList(tx)))
            // A PURE EFFECT rides along and is not restored (A2).
            tx.focus(field)
            // `clear` inside a named group is refused at apply (D4).
            app.post { tx in tx.clear(field) }
        }
        tx.button("star") { tx in  // button#1
            tx.write(status, .str("starred"))
            // NAMED AFTER THE FACT; the marker still rides at the HEAD of the
            // batch (crates/kaya/src/app.rs's undoable_puts_the_marker_at_the_head).
            tx.undoable("star")
        }
        // No handler moves the cursor on its own, so the SCRIPT decides focus.
        tx.button("focus") { tx in tx.focus(field) }  // button#2
        // The inverse is an IDENTITY, not a content: the core captured the
        // entry and its order before the removal.
        tx.button("remove") { tx in  // button#3
            guard let first = todos.items(tx).first else {
                let total = todos.items(tx).count
                tx.write(status, .str("nothing to remove, \(total) total"))
                return
            }
            tx.undoable("remove \(first.value.title)")
            todos.remove(tx, first.key)
            let total = todos.items(tx).count
            tx.write(status, .str("removed \(first.value.title), \(total) total"))
            tx.write(keys, .str(keyList(tx)))
        }
        for row in todos.rows {
            row.row {
                row.label(row.title)
                // UNBOUND on purpose: the copy owns its text and the app folds it.
                row.t.entry { tx, path, text in
                    let key = rowKey(path)
                    if text.isEmpty {
                        rowNotes.removeValue(forKey: key)
                    } else {
                        rowNotes[key] = text
                    }
                    tx.write(notes, .str(noteList()))
                }
            }
        }
    }
    // The scene types with REAL keystrokes, so something must hold focus.
    tx.focus(field)
    tx.mount(root)
}

app.run()
