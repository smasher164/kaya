// The progress conformance scene, Swift port. See
// guests/rust/progress.rs and tools/scenes/progress.steps.

import Foundation

let app = KayaApp()

app.build { tx in
    tx.window(title: "progress")
    let root = tx.column {
        tx.progress(value: 0.25)  // progress#0
        tx.progress(indeterminate: true)  // progress#1
    }
    tx.mount(root)
}

app.run()
