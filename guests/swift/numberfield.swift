// The number field scene, Swift port — guests/rust/numberfield.rs,
// tools/scenes/numberfield.steps, docs/number-field-plan.md.

import Foundation
import Kaya

struct Line: KayaGen {
    var name: String
    var qty: Double
}

// The harness's own value spelling (crates/kaya/src/harness.rs).
func spelled(_ v: Double) -> String {
    var s = String(format: "%.6f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

KayaApp.run { app in
    var commits = 0

    app.build { tx in
        let commitText = tx.signal(.str("commits: 0"))
        let rowText = tx.signal(.str("row: none"))
        let amountValue = tx.signal(.f64(0.0))
        let lines = lineCollection(tx)

        let root = tx.column { root in
            tx.setA11yId(tx.label(bind: commitText), "commits")
            tx.setA11yId(tx.label(bind: rowText), "row")
            let amount = tx.numberField(
                min: 0.0, max: 100.0, step: 0.5, bind: amountValue,
                onCommit: { tx, _ in
                    commits += 1
                    tx.write(commitText, .str("commits: \(commits)"))
                })
            tx.setA11yId(amount, "amount")
            tx.setA11yLabel(amount, "Amount")
            tx.setA11yId(tx.entry(), "note")
            let forty = tx.button("forty") { tx in
                // Must NOT come back as a commit.
                tx.write(amountValue, .f64(40.0))
            }
            tx.setA11yId(forty, "forty")
            for row in lines.rows {
                row.label(row.name)
                let qty = row.numberField(
                    value: row.qty, min: 0.0,
                    onCommit: { tx, keys, v in
                        guard case .str(let key) = keys[0] else { return }
                        tx.write(rowText, .str("row \(key): \(spelled(v))"))
                    })
                row.t.setA11yId(qty, "qty")
            }
            return root
        }
        tx.mount(root)

        lines.insert(tx, .str("a"), Line(name: "a", qty: 1.0))
        lines.insert(tx, .str("b"), Line(name: "b", qty: 2.0))
    }
}
