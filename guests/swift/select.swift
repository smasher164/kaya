// The select scene, Swift port — guests/rust/select.rs,
// tools/scenes/select.steps.

import Foundation
import Kaya

let options = ["Red", "Green", "Blue"]

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "select")
        let picked = tx.signal(.str("picked: Red"))

        let root = tx.column { root in
            tx.select(options, selected: 0) { t, index in
                t.write(picked, .str("picked: \(options[index])"))
            }
            tx.label(bind: picked)  // label#0
            return root
        }
        tx.mount(root)
    }
}
