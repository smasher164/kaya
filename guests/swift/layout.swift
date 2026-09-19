// The layout scene, Swift port — guests/rust/layout.rs,
// tools/scenes/layout.steps.

import Foundation
import Kaya

KayaApp.run { app in
    app.build { tx in
        let probe = tx.signal(.str("Layout probe"))
        let tail = tx.signal(.str("tail"))
        let mixed = tx.signal(.str("mixed"))
        let nested = tx.signal(.str("nested"))
        let deep = tx.signal(.str("deep"))

        let root = tx.column { root in
            tx.label(bind: probe)  // label#0

            tx.row { _ in
                tx.button("A")
                tx.button("longer")
                tx.label(bind: tail)  // label#1
            }

            tx.row { _ in
                tx.checkbox("check")
                tx.label(bind: mixed)  // label#2
                tx.slider(min: 0.0, max: 1.0, value: 0.5, grow: 1)
            }

            tx.row { _ in
                tx.slider(min: 0.0, max: 1.0, value: 0.25, grow: 1)
                tx.slider(min: 0.0, max: 1.0, value: 0.75, grow: 3)
            }

            tx.column { _ in
                tx.label(bind: nested)  // label#3
                tx.row { _ in
                    tx.label(bind: deep)  // label#4
                    tx.button("x")
                }
            }
            return root
        }
        tx.mount(root)
    }
}
