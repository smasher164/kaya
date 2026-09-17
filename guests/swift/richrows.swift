// The rich rows scene, Swift port — guests/rust/richrows.rs,
// tools/scenes/richrows.steps: a rich textarea per stamped ROW whose
// document is a FIELD of the row (docs/rich-text-plan.md §19). The app
// writes a copy's document by patching its row, and a copy's own act
// folds into the row the app reads back.

import Foundation

struct Note: KayaGen {
    var title: String
    var body: KayaDocument
}

/// The core's spelling of runs (`expect_runs`), so the row's field and
/// the core's mirror are compared as one string.
func spell(_ runs: [KayaRun]) -> String {
    runs.map { run in
        run.value == "true"
            ? "\(run.range.lowerBound):\(run.range.upperBound) \(run.name)"
            : "\(run.range.lowerBound):\(run.range.upperBound) \(run.name)=\(run.value)"
    }.joined(separator: "|")
}

func keyText(_ key: KayaValue) -> String {
    if case .str(let s) = key { return s }
    return "\(key)"
}

let app = KayaApp()

app.build { tx in
    let notes = noteCollection(tx)
    let last = tx.signal(.str(""))
    let view = tx.signal(.str(""))

    func row(_ t: KayaAppTx, _ key: KayaValue) -> Note {
        guard let note = notes.items(t).first(where: { $0.key == key })?.value else {
            preconditionFailure("richrows: no row \(key)")
        }
        return note
    }

    // An undo or redo moved the row back: the app reads ITS OWN mirror of
    // row b, which is the fold a restored Blob field lands in.
    func restored(_ t: KayaAppTx, _ label: String, _ delta: KayaUndoDelta) {
        let note = row(t, .str("b"))
        t.write(view, .str("\(note.body.text) | \(spell(note.body.runs))"))
    }

    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Undo", role: KayaAppTx.roleUndo),
            tx.item("Redo", role: KayaAppTx.roleRedo),
        ])
    tx.window(
        title: "richrows", onUndone: restored, onRedone: restored, menus: [edit])

    let root = tx.column {
        tx.label(bind: last)  // label#0
        tx.label(bind: view)  // label#1
        tx.row {
            tx.button("patch b") { t in  // button#0
                t.undoable("patch b")
                notes.patch(t, .str("b")).set(
                    \.body, KayaDocument("Patched").italic(0..<7))
            }
            tx.button("read a") { t in  // button#1
                let note = row(t, .str("a"))
                t.write(view, .str("\(note.body.text) | \(spell(note.body.runs))"))
            }
        }
        for r in notes.rows {
            r.column {
                r.label(r.title)
                let body = r.textarea(document: r.body)
                r.t.setA11yId(body, "body")
                // The row's field already carries the copy's act when
                // these fire: the app reads the row, never the widget.
                app.onEdit(body) { t, keys, _ in
                    let note = row(t, keys[0])
                    t.write(last, .str("\(keyText(keys[0])): \(spell(note.body.runs))"))
                }
                app.onFormat(body) { t, keys, _ in
                    let note = row(t, keys[0])
                    t.write(last, .str("\(keyText(keys[0])): \(spell(note.body.runs))"))
                }
            }
        }
    }
    tx.mount(root)

    notes.insert(tx, .str("a"), Note(
        title: "a", body: KayaDocument("Héllo world").bold(0..<6)))
    notes.insert(tx, .str("b"), Note(
        title: "b", body: KayaDocument("Second note").link(7..<11, "https://kaya.dev")))
}

app.run()
