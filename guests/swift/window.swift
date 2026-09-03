// The window scene, Swift port — guests/rust/window.rs,
// tools/scenes/window.steps.

import Foundation

let app = KayaApp()

app.build { tx in
    tx.window(title: "window probe", width: 640.0, height: 400.0)
    let probe = tx.signal(.str("window probe"))
    let root = tx.column {
        tx.label(bind: probe)  // label#0
    }
    tx.mount(root)
}

app.run()
