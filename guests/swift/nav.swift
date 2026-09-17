// The nav scene, Swift port — guests/rust/nav.rs, tools/scenes/nav.steps.

import Foundation

let DETAIL: UInt64 = 7
let SETTINGS: UInt64 = 8

let app = KayaApp()

app.build { tx in
    tx.window(title: "nav")
    let status = tx.signal(.str("at root"))
    let root = tx.column { root in
        tx.label(bind: status)  // label#0
        tx.button(
            "open detail",
            onClick: { inner in  // button#0
            inner.pushEntry(
                DETAIL, title: "detail",
                onPopped: { tx2 in tx2.write(status, .str("popped detail")) })
            let pane = inner.column { pane in
                let caption = inner.signal(.str("detail pane"))
                inner.label(bind: caption)
                return pane
            }
            inner.mountIn(DETAIL, pane)
            inner.write(status, .str("pushed detail"))
            })
        tx.button(
            "open settings",
            onClick: { inner in  // button#1
            // Nothing has popped, so the handler agrees and confirms.
            inner.pushEntry(
                SETTINGS, title: "settings", interceptBack: true,
                onBackRequested: { tx2 in
                    tx2.write(status, .str("back requested"))
                    tx2.popEntry()
                })
            let pane = inner.column { pane in
                let caption = inner.signal(.str("settings pane"))
                inner.label(bind: caption)
                return pane
            }
            inner.mountIn(SETTINGS, pane)
            inner.write(status, .str("pushed settings"))
            })
        return root
    }
    tx.mount(root)
}

app.run()
