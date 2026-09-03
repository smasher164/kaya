// The panels scene, Swift port — guests/rust/panels.rs,
// tools/scenes/panels.steps.

import Foundation

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    tx.window(title: "panels")
    status = tx.signal(.str("two panels"))
    let root = tx.column {
        tx.label(bind: status)  // label#0
    }
    tx.mount(root)

    tx.createWindow(
        1, title: "inspector", width: 480.0, height: 320.0, vetoClose: true,
        onCloseRequested: { tx2 in
            tx2.write(status, .str("close requested"))
            tx2.destroyWindow(1)
        })
    let auxRoot = tx.column {
        let caption = tx.signal(.str("inspector pane"))
        tx.label(bind: caption)  // label#1
    }
    tx.mountIn(1, auxRoot)
}

app.run()
