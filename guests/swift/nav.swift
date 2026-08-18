// The nav conformance scene, Swift port — the serial navigation grammar.
// The covered root is RETAINED (status keeps taking writes while
// covered); a programmatic popEntry does not echo entry_popped, so the
// settings round's final status stays "back requested". See
// guests/rust/nav.rs and tools/scenes/nav.steps.

import Foundation

let DETAIL: UInt64 = 7
let SETTINGS: UInt64 = 8

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    tx.window(title: "nav")
    status = tx.signal(.str("at root"))
    let root = tx.column {
        tx.label(bind: status)  // label#0
        tx.button(
            "open detail",
            onClick: { inner in  // button#0
            inner.pushEntry(
                DETAIL, title: "detail",
                onPopped: { tx2 in tx2.write(status, .str("popped detail")) })
            let pane = inner.column {
                let caption = inner.signal(.str("detail pane"))
                inner.label(bind: caption)
            }
            inner.mountIn(DETAIL, pane)
            // The covered root keeps taking writes — retention.
            inner.write(status, .str("pushed detail"))
            })
        tx.button(
            "open settings",
            onClick: { inner in  // button#1
            // The veto class: nothing has popped; agree and confirm.
            inner.pushEntry(
                SETTINGS, title: "settings", interceptBack: true,
                onBackRequested: { tx2 in
                    tx2.write(status, .str("back requested"))
                    tx2.popEntry()
                })
            let pane = inner.column {
                let caption = inner.signal(.str("settings pane"))
                inner.label(bind: caption)
            }
            inner.mountIn(SETTINGS, pane)
            inner.write(status, .str("pushed settings"))
            })
    }
    tx.mount(root)
}

app.run()
