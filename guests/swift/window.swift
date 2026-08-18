// The window conformance scene, Swift port — see guests/rust/window.rs.
// The title must MATERIALIZE (the runner reads the real title bar), and
// 640x400 is deliberately off the 540x330 default so an ignored size
// request cannot pass by luck. Desktop-only: phones reject the size.

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
