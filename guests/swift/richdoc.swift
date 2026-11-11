// The rich document scene, Swift port — guests/rust/richdoc.rs,
// tools/scenes/richdoc.steps (docs/rich-document-plan.md §9 step 2): a
// heading, a body paragraph with a preset colour, a bullet list with a
// nested item, a numbered list and a checklist, then the paragraph acts from
// buttons, the platform's colour picker and a `.kdoc` round trip. label#1 is
// the binding's own Document, folded from the same deltas, so it must spell
// what the core holds.

import Foundation
import Kaya

// BYTE-IDENTICAL to guests/rust/richdoc.rs's DOC.
let document = "Groceries\nFresh from the market.\nApples\nGreen ones\nBread\nWash\nSlice\nMilk\nEggs"

func spell(_ runs: [KayaRun]) -> String {
    runs.map { run in
        run.isFlag
            ? "\(run.range.lowerBound):\(run.range.upperBound) \(run.name)"
            : "\(run.range.lowerBound):\(run.range.upperBound) \(run.name)=\(run.value)"
    }.joined(separator: "|")
}

let seeded = KayaDocument(document)
    .block(0..<9, .heading1)
    .color(25..<31, "#016FEF")
    .list(33..<56, .bullet)
    .indent(40..<50, 1)
    .list(57..<67, .numbered)
    .checked(68..<72)
    .list(68..<77, .check)

KayaApp.run { app in
    app.build { tx in
        let edit = tx.menu(
            "Edit",
            items: [
                tx.item("Cut", role: .cut),
                tx.item("Copy", role: .copy),
                tx.item("Paste", role: .paste),
            ])
        tx.window(title: "richdoc", width: 560, height: 620, menus: [edit])
        let last = tx.signal(.str(""))
        let runs = tx.signal(.str(spell(seeded.runs)))
        let kdoc = tx.signal(.str(""))

        // A SELF-REFERENCE, not a smuggle: the textarea's own onEdit reads
        // the document of the widget being declared.
        var editor: KayaWidget! = nil

        let root = tx.column { root in
            editor = tx.textarea(
                rich: true,
                onEdit: { t, edit in
                    let mirror = spell(app.document(editor).runs)
                    let inserted = edit.inserted.replacingOccurrences(of: "\n", with: "\\n")
                    t.write(
                        last,
                        .str("edit \(edit.range.lowerBound):\(edit.range.upperBound) <\(inserted)> "
                            + "\(edit.source?.name ?? "?") [\(spell(edit.runs))]"))
                    t.write(runs, .str(mirror))
                },
                onFormat: { t, act in
                    let mirror = spell(app.document(editor).runs)
                    t.write(
                        last,
                        .str("format \(act.range.lowerBound):\(act.range.upperBound) \(act.name)="
                            + "\(act.value ?? "off")"))
                    t.write(runs, .str(mirror))
                })
            tx.setGrow(editor, 1)
            tx.setA11yId(editor, "doc")
            tx.setA11yLabel(editor, "Document")
            tx.label(bind: last)  // label#0
            tx.label(bind: runs)  // label#1
            tx.label(bind: kdoc)  // label#2
            tx.row { _ in
                tx.button("numbered") { t in t.setList(editor, .numbered) }  // button#0
                tx.button("indent") { t in t.indent(editor) }  // button#1
                tx.button("red") { t in t.color(editor, "#DD1F24") }  // button#2
                tx.button("colour") { t in t.pickTextColor(editor) }  // button#3
                tx.button("kdoc") { t in  // button#4
                    let now = app.document(editor)
                    let bytes = now.toKdoc()
                    let back = try KayaDocument.fromKdoc(bytes)
                    t.setDocument(editor, back.document)
                    t.write(
                        kdoc,
                        .str("kdoc \(bytes.count) bytes, read_only \(back.readOnly ?? "none"), "
                            + "same \(back.document == now)"))
                    t.write(runs, .str(spell(back.document.runs)))
                }
            }
            return root
        }
        tx.mount(root)
        tx.setDocument(editor, seeded)
    }
}
