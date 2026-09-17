// The rich label scene, Swift port — guests/rust/richlabel.rs,
// tools/scenes/richlabel.steps (docs/rich-text-plan.md R8, §15): a label
// carries the inline vocabulary read-only. THE OFFSETS ARE UTF-8 BYTES: the
// é in the first word is what makes a UTF-16 reader fail
// (docs/ranges-units.md).

import Foundation

let document = "Héllo world, code"
let title = "Heading with italic"

/// The core's spelling of runs (`expect_runs`), so the binding's document
/// and the core's mirror are compared as one string.
func spell(_ runs: [KayaRun]) -> String {
    runs.map { run in
        run.isFlag
            ? "\(run.range.lowerBound):\(run.range.upperBound) \(run.name)"
            : "\(run.range.lowerBound):\(run.range.upperBound) \(run.name)=\(run.value)"
    }.joined(separator: "|")
}

let app = KayaApp()

app.build { tx in
    tx.window(title: "richlabel")
    let runs = tx.signal(.str(""))

    // A widget parents at CREATION, so the two labels ride out through
    // these vars (docs/traps.md, result builders).
    var body: KayaWidget! = nil
    var heading: KayaWidget! = nil

    let root = tx.column {
        let bodyText = tx.signal(.str(""))
        let headingText = tx.signal(.str(title))
        body = tx.label(bind: bodyText, rich: true)  // label#0
        tx.setA11yId(body, "body")
        heading = tx.label(bind: headingText, role: .heading, rich: true)  // label#1
        tx.setA11yId(heading, "heading")
        let mirror = tx.label(bind: runs)  // label#2
        tx.setA11yId(mirror, "runs")
        tx.row {
            tx.button("seed") { t in  // button#0
                let doc = KayaDocument(document)
                    .bold(0..<6)
                    .link(7..<12, "https://kaya.dev")
                    .mark(14..<18, "code", true)
                let heads = KayaDocument(title).mark(13..<19, "italic", true)
                t.setDocument(body, doc)
                t.setDocument(heading, heads)
                t.write(runs, .str(spell(doc.runs)))
            }
            tx.button("insert") { t in  // button#1
                let edit = KayaEdit.insert(at: 6, ", big").mark(2..<5, "italic", true)
                t.applyEdit(body, edit)
                t.write(runs, .str(spell(app.document(body).runs)))
            }
            // THE RANGED ACT ON A LABEL (docs/rich-text-plan.md §17): the
            // label's own document written by range, no selection to move.
            tx.button("mark") { t in  // button#2
                t.formatRange(body, 1..<4, "italic", true)
                t.unformatRange(body, 0..<3, "bold")  // "Hé": byte 2 is inside the é
                t.write(runs, .str(spell(app.document(body).runs)))
            }
        }
    }
    tx.mount(root)
}

app.run()
