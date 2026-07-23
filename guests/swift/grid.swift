// The grid conformance scene, Swift port. See
// guests/rust/grid.rs and tools/scenes/grid.steps.

import Foundation

let app = KayaApp()

app.build { tx in
    tx.window(title: "grid")
    let root = tx.column {
        tx.grid(columns: 2) {
            tx.label("Name:")  // label#0
            tx.label("Ada Lovelace")  // label#1
            tx.label("Role:")  // label#2
            tx.label("Engine programmer")  // label#3
        }
        tx.row(grow: 1.0) {
            tx.button("left")  // button#0
            tx.spacer()
            tx.button("right")  // button#1
        }
    }
    tx.mount(root)
}

app.run()
