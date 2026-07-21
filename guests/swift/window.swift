// The window conformance scene, Swift port — see guests/rust/window.rs
// for the full rationale. The title must MATERIALIZE (the runner reads
// the real title bar, never the model's copy), and the advisory size
// request must be honored on a desktop — 640x400, deliberately off the
// 540x330 default so an ignored request cannot pass by luck. A desktop
// scene: phones reject the size by physics, so runners register it on
// the desktops only (DESIGN.md, Presentation contexts).

import Foundation

let app = KayaApp()

app.build { tx in
    tx.windowTitle("window probe")
    tx.windowSize(640.0, 400.0)
    let probe = tx.signal(.str("window probe"))
    let root = tx.column {
        tx.label(bind: probe)  // label#0
    }
    tx.mount(root)
}

app.run()
