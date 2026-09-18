// The adaptive scene, Swift port — guests/rust/adaptive.rs,
// tools/scenes/adaptive.steps.

import Foundation
import Kaya

let app = KayaApp()

var vertical = false

let dash: KayaWidget = app.build { tx in
    // Above the breakpoint, so the resize half crosses it both ways.
    tx.window(title: "adaptive", width: 900, height: 600)
    let alpha = tx.signal(.str("alpha"))
    let longer = tx.signal(.str("a longer label"))
    let steady = tx.signal(.str("steady"))

    let (root, dash) = tx.column { root -> (KayaWidget, KayaWidget) in
        let dash = tx.row { dash in  // row#0: the flip subject.
            tx.setA11yId(dash, "dash")
            tx.label(bind: alpha)  // label#0
            tx.label(bind: longer)  // label#1
            return dash
        }
        // column#1: the control group, whose axis never moves.
        tx.column { steadyColumn in
            tx.setA11yId(steadyColumn, "steady")
            tx.label(bind: steady)  // label#2
        }
        tx.button(
            "flip",
            onClick: { inner in  // button#0
                vertical = !vertical
                inner.setAxis(dash, vertical ? .vertical : .horizontal)
            })
        // row#1: the breakpoint subject, which no handler touches.
        tx.row { narrow in
            tx.setA11yId(narrow, "narrow")
            narrow.stackWhen(.compact)
            let one = tx.signal(.str("one"))
            let two = tx.signal(.str("a wider two"))
            tx.label(bind: one)  // label#3
            tx.label(bind: two)  // label#4
        }
        // grid@sheet: three columns regular, one compact (D6.2).
        tx.grid(columns: 3) { sheet in
            tx.setA11yId(sheet, "sheet")
            sheet.columnsWhen(.compact, 1)
            for text in ["c1", "c2", "c3", "c4", "c5", "c6"] {
                tx.label(bind: tx.signal(.str(text)))  // label#5..#10
            }
        }
        // grid@fit: no count, a 240-point floor, the WIDTH decides
        // (docs/layout-knobs-plan.md §3). Buttons, so the label ordinals
        // above stay put.
        tx.grid(columns: 3) { fit in
            tx.setColumnsAuto(fit, 240)
            tx.setA11yId(fit, "fit")
            tx.button("f1")  // button#1
            tx.button("f2")
            tx.button("f3")
        }
        return (root, dash)
    }
    tx.mount(root)
    return dash
}

app.run()
