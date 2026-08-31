// The adaptive conformance scene, Swift port — see guests/rust/adaptive.rs
// for the full rationale. row@dash flips by a HANDLER (D2's user-driven
// toggle); row@narrow carries the chained breakpoint (D3, size classes
// ruled 2026-08-31): stackWhen(.compact) stacks it vertically while the
// window's size class is compact (below 600 points on every desktop)
// and reverts on leaving the class. The byte-frozen contract is
// tools/scenes/adaptive.steps.

import Foundation

let app = KayaApp()

var dash: KayaWidget!
var vertical = false

app.build { tx in
    // Explicit size: the desktop start must sit ABOVE the breakpoint's
    // threshold so the scene's resize half crosses it both ways
    // deterministically.
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
        // column#1: the control group — its axis answers the creation
        // kind's own and never moves.
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
        // row#1: the BREAKPOINT subject (D3) — declared data,
        // core-evaluated; the handler never touches it.
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
