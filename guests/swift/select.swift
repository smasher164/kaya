// The select conformance scene, Swift port. See
// guests/rust/select.rs and tools/scenes/select.steps.

import Foundation

let options = ["Red", "Green", "Blue"]

let app = KayaApp()

app.build { tx in
    tx.window(title: "select")
    let picked = tx.signal(.str("picked: Red"))

    let root = tx.column {
        tx.select(options, selected: 0) { t, index in
            t.write(picked, .str("picked: \(options[index])"))
        }
        tx.label(bind: picked)  // label#0
    }
    tx.mount(root)
}

app.run()
