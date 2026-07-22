// The radio conformance scene, Swift port. See
// guests/rust/radio.rs and tools/scenes/radio.steps.

import Foundation

let options = ["Small", "Medium", "Large"]

let app = KayaApp()

app.build { tx in
    tx.windowTitle("radio")
    let size = tx.signal(.str("size: Small"))

    let root = tx.column {
        tx.radio(options, selected: 0) { t, index in
            t.write(size, .str("size: \(options[index])"))
        }
        tx.label(bind: size)  // label#0
    }
    tx.mount(root)
}

app.run()
