// The grid scene, Swift port — guests/rust/grid.rs, tools/scenes/grid.steps.

import Foundation
import Kaya

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "grid")
        let root = tx.column { root in
            tx.grid(columns: 2) { _ in
                tx.label("Name:")  // label#0
                tx.label("Ada Lovelace")  // label#1
                tx.label("Role:")  // label#2
                tx.label("Engine programmer")  // label#3
            }
            tx.row(grow: 1.0) { _ in
                tx.button("left")  // button#0
                tx.spacer()
                tx.button("right")  // button#1
            }
            return root
        }
        tx.mount(root)
    }
}
