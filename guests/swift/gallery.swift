// The gallery scene from Swift: a row with a checkbox and its status
// label, and a row with a slider and its volume label. Both controls
// own their state and report each change; the app answers by writing
// the paired signal — the entry's uncontrolled contract, with a bool
// and a Double.

import Foundation

let app = KayaApp()

// The construction sugar: constructors carry their handlers,
// result-builder containers take their children, and the build closure
// reads as the tree.
app.build { tx in
    let status = tx.signal(.str("urgent: false"))
    let volume = tx.signal(.str("volume: 50%"))

    let root = tx.column {
        tx.row {
            tx.checkbox("urgent") { t, checked in
                t.write(status, .str("urgent: \(checked)"))
            }
            tx.label(bind: status)
        }
        tx.row {
            // Integer percent, so every language's formatting agrees.
            tx.slider(min: 0.0, max: 1.0, value: 0.5) { t, value in
                t.write(volume, .str("volume: \(Int((value * 100).rounded()))%"))
            }
            tx.label(bind: volume)
        }
    }
    tx.mount(root)
}

app.run()
