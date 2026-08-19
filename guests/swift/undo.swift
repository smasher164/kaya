// The undo scene, Swift port: two tiers, one Edit menu, and one ledger
// that orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3). See
// guests/rust/undo.rs and tools/scenes/undo.steps.
//
// WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. `tx.undoable(...)`
// names a transaction, and that name is the step; the core keeps the
// inverse and hands it back through the window's onUndone. There is no
// undo stack in this file and no re-run of any handler.
//
// THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S. Both tiers arrive
// through the same Edit>Undo item, and which one answers is kaya's
// routing question, not the app's (D6).
//
// The add button appends a todo AND empties the field, in TWO
// transactions deliberately, so one Cmd+Z takes back the ADD and not
// the CLEAR (docs/undo-plan.md §2). The key comes from insertFresh
// (docs/fresh-key-plan.md).

import Foundation

struct Todo: KayaGen {
    var title: String
}

let app = KayaApp()

// The fold: widget-owned state arrives as occurrences. Two variables,
// because the payload's path is what tells a row's field from the draft.
var draft = ""
var rowNotes: [Int64: String] = [:]

var status: KayaSignal!
var history: KayaSignal!
var keys: KayaSignal!
var notes: KayaSignal!
var field: KayaWidget!
var todos: KayaRecordCollection<Todo>!

/// What the history label says a step was. A typing episode has no
/// authored name and kaya invents none (docs/undo-plan.md D8).
func what(_ label: String) -> String {
    label.isEmpty ? "typing" : label
}

/// The app's collection mirror, rendered: every key it holds, in order.
/// THIS IS THE ONLY PART OF AN UNDO A COUNT CANNOT SEE — a restored
/// entry that came back under a fresh name, or at the end instead of
/// where it was, leaves every total in this file correct (D5).
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

/// The row a stamped copy's occurrence names: the copy's key path, which
/// for a top-level For is one key — the todo's own.
func rowKey(_ path: [KayaValue]) -> Int64 {
    guard case .i64(let n) = path[0] else {
        preconditionFailure("kaya: a minted key is I64")
    }
    return n
}

/// The app's copy of what is typed in the ROWS, by key. An undone note
/// arrives naming (template node, key path), so an app with two rows can
/// put it back in the right one. Sorted, because a Dictionary has no
/// order and the script compares bytes.
func noteList() -> String {
    if rowNotes.isEmpty {
        return "no notes"
    }
    let rendered = rowNotes.keys.sorted().map { key in "\(key)=\(rowNotes[key]!)" }
    return "notes \(rendered.joined(separator: ","))"
}

/// One texts run, folded into the app's two mirrors. The empty path is
/// the draft; a path names a row. AN EMPTY NOTE IS NO NOTE, so the
/// restore of a row's field to "" has to REMOVE the key.
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
    // THE GESTURE LAYER: an app declares the two items and writes nothing
    // else. They work out their own enablement from what the ledger holds.
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Undo", role: KayaAppTx.roleUndo),
            tx.item("Redo", role: KayaAppTx.roleRedo),
        ])
    // Per window, and PERSISTENT. The binding has already reconciled its
    // collection mirror from this payload before the handler runs.
    tx.window(
        title: "undo",
        onUndone: { tx, label, delta in
            // THE DELTA IS THE ONLY NOTIFICATION for that text: an undo
            // is a programmatic write and never echoes (D5). The run is
            // walked whole, because an entry NAMES the field it restores.
            foldTexts(delta.texts)
            let total = todos.items(tx).count
            tx.write(history, .str("undid \(what(label)), \(total) total"))
            // ONE TRANSACTION WITH THE LABEL ABOVE, deliberately: the
            // script reads that label first, so this one is the app's own
            // answer rather than the value the core restored on its way
            // past.
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
                // NOT A STEP, so it names no group and the forward
                // history survives it. It is also the one place this app
                // READS ITS OWN DRAFT out loud.
                let total = todos.items(tx).count
                tx.write(status, .str("nothing to add, \(total) total"))
                return
            }
            tx.undoable("add \(draft)")
            // NO KEY, AND NO COUNTER TO GET WRONG: the binding mints the
            // name and hands it back; @discardableResult lets this read
            // as a statement.
            todos.insertFresh(tx, Todo(title: draft))
            let total = todos.items(tx).count
            tx.write(status, .str("added \(draft), \(total) total"))
            tx.write(keys, .str(keyList(tx)))
            // A PURE EFFECT rides along and is simply not restored (A2).
            tx.focus(field)
            // FINISHING THE FORM IS NOT PART OF THE STEP: its own
            // transaction, so undoing the add does not put the draft back
            // beside a todo that is gone, and `clear` inside a group would
            // be refused anyway. The field's own text_changed("") re-enters
            // through the fold.
            app.post { tx in tx.clear(field) }
        }
        tx.button("star") { tx in  // button#1
            tx.write(status, .str("starred"))
            // NAMED AFTER THE FACT, which is the ordinary way a handler
            // works: it builds first and knows what the step was
            // afterwards. The marker still rides at the HEAD of the batch
            // (crates/kaya/src/app.rs's
            // undoable_puts_the_marker_at_the_head test).
            tx.undoable("star")
        }
        // THE SCENE'S WAY BACK TO THE FIELD: `star` does not move the
        // cursor on its own, so the routing question ("what is focused?")
        // stays visible in the script rather than hidden in a handler.
        tx.button("focus") { tx in tx.focus(field) }  // button#2
        // THE STEP WHOSE INVERSE IS AN IDENTITY, not a content: the core
        // captured the entry and its order before the removal. The target
        // is the collection's FIRST entry, the model's own answer.
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
                // THE ROW'S OWN FIELD, uncontrolled like its live siblings.
                // The handler co-locates at the constructor and still
                // registers against the TEMPLATE NODE, so each edit arrives
                // with the stamped copy's keys — the same (node, path) pair
                // the undo payload names it by.
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
    // THE SCENE TYPES WITH REAL KEYSTROKES, so something has to hold
    // focus when it does.
    tx.focus(field)
    tx.mount(root)
}

app.run()
