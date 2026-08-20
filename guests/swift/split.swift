// The split conformance scene, Swift port — adaptive panes. The guest
// asks for the presentation ONCE and does nothing adaptive after: the
// platform re-decides as the size class changes, and there is no prop
// for WHICH entries present.
//
// TWO scripts drive this ONE app. See guests/rust/split.rs,
// tools/scenes/split.steps and tools/scenes/listdetail.steps.

import Foundation

let DETAIL: UInt64 = 7

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    tx.window(title: "split", panes: 2)
    status = tx.signal(.str("list pane"))
    let root = tx.column {
        // Authored ids so the REAL-TREE read can address these: an index
        // read passes for an arm that ran and drew nothing.
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
