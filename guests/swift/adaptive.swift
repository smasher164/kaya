// The adaptive scene, Swift port — guests/rust/adaptive.rs,
// tools/scenes/adaptive.steps.

import Foundation

let app = KayaApp()

var dash: KayaWidget!
var vertical = false

app.build { tx in
    // Above the breakpoint, so the resize half crosses it both ways.
    tx.window(title: "adaptive", width: 900, height: 600)
    let alpha = tx.signal(.str("alpha"))
    let longer = tx.signal(.str("a longer label"))
    let steady = tx.signal(.str("steady"))

    let root = tx.column {
        dash = tx.row {  // row#0: the flip subject.
            tx.label(bind: alpha)  // label#0
            tx.label(bind: longer)  // label#1
        }
        tx.setA11yId(dash, "dash")
        // column#1: the control group, whose axis never moves.
        let steadyColumn = tx.column {
            tx.label(bind: steady)  // label#2
        }
        tx.setA11yId(steadyColumn, "steady")
        tx.button(
            "flip",
            onClick: { inner in  // button#0
                vertical = !vertical
                inner.setAxis(dash, vertical ? .vertical : .horizontal)
            })
        // row#1: the breakpoint subject, which no handler touches.
        let narrow = tx.row {
            let one = tx.signal(.str("one"))
            let two = tx.signal(.str("a wider two"))
            tx.label(bind: one)  // label#3
            tx.label(bind: two)  // label#4
        }
        tx.setA11yId(narrow, "narrow")
        narrow.stackWhen(.compact)
    }
    tx.mount(root)
}

app.run()
