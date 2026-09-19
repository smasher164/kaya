// The progress scene, Swift port — guests/rust/progress.rs,
// tools/scenes/progress.steps.

import Foundation
import Kaya

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "progress")
        let root = tx.column { root in
            tx.progress(value: 0.25)  // progress#0
            tx.progress(indeterminate: true)  // progress#1
            return root
        }
        tx.mount(root)
    }
}
