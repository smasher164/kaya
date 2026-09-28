// The scroll scene, Swift port — guests/rust/scroll.rs,
// tools/scenes/scroll.steps.

import Foundation
import Kaya

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "scroll")
        let status = tx.signal(.str("at top"))
        let root = tx.column { root in
            tx.label(bind: status)  // label#0
            tx.scroll(grow: 1) { rows in
                tx.setA11yId(rows, "rows")
                tx.column { _ in
                    for i in 1...29 {
                        let caption = tx.signal(.str("row \(i)"))
                        tx.label(bind: caption)
                    }
                    tx.button(
                        "bottom",
                        onClick: { inner in  // button#0
                            inner.write(status, .str("bottom clicked"))
                        })
                }
            }
            // A strip wider than the window, scrolled sideways
            // (docs/hscroll-plan.md), addressed as scroll@strip.
            tx.scroll(axis: .horizontal) { strip in
                tx.setA11yId(strip, "strip")
                tx.row { _ in
                    for i in 1...19 {
                        let caption = tx.signal(.str("card \(i)"))
                        tx.label(bind: caption)
                    }
                    tx.setA11yId(
                        tx.button(
                            "last card",
                            onClick: { inner in
                                inner.write(status, .str("last card clicked"))
                            }), "last")
                }
            }
            return root
        }
        tx.mount(root)
    }
}
