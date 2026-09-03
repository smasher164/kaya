// The split scene, Swift port — guests/rust/split.rs,
// tools/scenes/split.steps.

import Foundation

let DETAIL: UInt64 = 7

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    tx.window(title: "split", panes: 2)
    status = tx.signal(.str("list pane"))
    let root = tx.column {
        // Authored ids: an index read passes for an arm that drew nothing.
        tx.setA11yId(tx.label(bind: status), "list")  // label#0
        tx.button(
            "open detail",
            onClick: { inner in  // button#0
            inner.pushEntry(
                DETAIL, title: "detail",
                onPopped: { tx2 in tx2.write(status, .str("popped detail")) })
            let pane = inner.column {
                let caption = inner.signal(.str("detail pane"))
                inner.setA11yId(inner.label(bind: caption), "detail")
            }
            inner.mountIn(DETAIL, pane)
            })
    }
    tx.mount(root)
}

app.run()
