// The stall scene, Swift port — guests/rust/stall.rs,
// tools/scenes/stall.steps.

import Foundation

// Past the watchdog's one-second threshold.
let blockSeconds = 2.5

// A day, never a literal park (docs/traps.md, the stall scene wedges for a DAY).
let wedgeSeconds = 86400.0

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    tx.window(title: "stall")
    status = tx.signal(.str("ready"))
    let root = tx.column {
        tx.setA11yId(tx.label(bind: status), "status")  // label#0

        // DELIBERATELY WRONG, and the only place in this repo that is.
        tx.button(
            "block",
            onClick: { inner in  // button#0
                Thread.sleep(forTimeInterval: blockSeconds)
            })
        tx.button(
            "ping",
            onClick: { inner in  // button#1
                try inner.write(status, .str("pinged"))
            })
        tx.button(
            "wedge",
            onClick: { inner in  // button#2
                Thread.sleep(forTimeInterval: wedgeSeconds)
            })
    }
    tx.mount(root)
}

app.run()
