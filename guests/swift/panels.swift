// The panels scene, Swift port — guests/rust/panels.rs,
// tools/scenes/panels.steps.

import Foundation
import Kaya

let app = KayaApp()

app.build { tx in
    tx.window(title: "panels")
    let status = tx.signal(.str("two panels"))
    let root = tx.column { root in
        tx.label(bind: status)  // label#0
        return root
    }
    tx.mount(root)

    tx.createWindow(
        1, title: "inspector", width: 480.0, height: 320.0, vetoClose: true,
        onCloseRequested: { tx2 in
            tx2.write(status, .str("close requested"))
            tx2.destroyWindow(1)
        })
    let auxRoot = tx.column { auxRoot in
        let caption = tx.signal(.str("inspector pane"))
        tx.label(bind: caption)  // label#1
        return auxRoot
    }
    tx.mountIn(1, auxRoot)
}

app.run()
