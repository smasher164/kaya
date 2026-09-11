// The rich text scene, Swift port — guests/rust/richtext.rs,
// tools/scenes/richtext.steps. THE OFFSETS ARE UTF-8 BYTES: the é in the
// first word is what makes a UTF-16 reader fail (docs/ranges-units.md).

import Foundation

let document = "Héllo world\nSecond line"

/// The core's spelling of runs (`expect_runs`), so the binding's document
/// and the core's mirror are compared as one string.
func spell(_ runs: [KayaRun]) -> String {
    runs.map { run in
        run.value == "true"
            ? "\(run.start):\(run.end) \(run.name)"
            : "\(run.start):\(run.end) \(run.name)=\(run.value)"
    }.joined(separator: "|")
}

let app = KayaApp()

app.build { tx in
    tx.window(title: "richtext")
    let last = tx.signal(.str(""))
    let runs = tx.signal(.str(""))

    // A widget parents at CREATION, so the editor rides out through this
    // var (docs/traps.md, result builders).
    var editor: KayaWidget! = nil

    let root = tx.column {
        editor = tx.textarea(
            rich: true,
            onEdit: { t, edit in
                let mirror = spell(app.document(editor).runs)
                t.write(
                    last,
                    .str("edit \(edit.start):\(edit.end) <\(edit.inserted)> "
                        + "[\(spell(edit.runs))]"))
                t.write(runs, .str(mirror))
            },
            onFormat: { t, act in
                let mirror = spell(app.document(editor).runs)
                t.write(
                    last,
                    .str("format \(act.start):\(act.end) \(act.name)="
                        + "\(act.value ?? "off")"))
                t.write(runs, .str(mirror))
            })
        tx.setA11yId(editor, "doc")
        tx.setA11yLabel(editor, "Document")
        tx.label(bind: last)  // label#0
        tx.label(bind: runs)  // label#1
        tx.row {
            tx.button("seed") { t in  // button#0
                let doc = KayaDocument(document)
                    .bold(0..<6)
                    .link(7..<12, "https://kaya.dev")
                    .block(13..<24, .heading2)
                t.setDocument(editor, doc)
                t.write(runs, .str(spell(doc.runs)))
            }
            tx.button("insert") { t in  // button#1
                let edit = KayaEdit.insert(at: 6, ", big").mark(2..<5, "italic", "true")
                t.applyEdit(editor, edit)
                t.write(runs, .str(spell(app.document(editor).runs)))
            }
            tx.button("select word") { t in  // button#2
                t.selectRange(editor, 0..<6)
            }
            tx.button("unbold") { t in  // button#3
                t.unformat(editor, "bold")
            }
            tx.button("heading") { t in  // button#4
                t.setBlock(editor, .heading1)
            }
            tx.button("focus") { t in  // button#5
                t.focus(editor)
            }
            tx.button("prefix") { t in  // button#6
                t.applyEdit(editor, KayaEdit.insert(at: 0, "> "))
                t.write(runs, .str(spell(app.document(editor).runs)))
            }
        }
    }
    tx.mount(root)
}

app.run()
