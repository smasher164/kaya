// The grow scene, Swift port — guests/rust/grow.rs, tools/scenes/grow.steps.

import Foundation

let app = KayaApp()

app.build { tx in
    let probe = tx.signal(.str("grow probe"))
    let one = tx.signal(.str("one"))

    let root = tx.column {
        tx.label(bind: probe, grow: 1)  // label#0
        tx.textarea(grow: 2)  // textarea#0
        tx.row(grow: 1, spacing: 12) {
            tx.label(bind: one, grow: 1)  // label#1
            tx.button("three", grow: 3)
        }
    }
    tx.mount(root)
}

app.run()
