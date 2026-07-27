// The split conformance scene, Swift port — adaptive list-detail via
// named arguments: listDetail: rides the window, pushEntry(title:,
// onPopped:) plus mountIn presents the detail.
//
// The guest asks for the presentation ONCE and then does nothing
// adaptive ever again. Everything after that is the platform
// re-deciding as the size class changes: an app does not write two
// layouts and pick one, and there is no prop for WHICH way it
// presents. Nothing here is split-specific except that one prop.
//
// TWO scripts drive this ONE app: split resizes and names the
// presentation on each side, listdetail asserts the bare invariant at
// whatever width its host gives. See guests/rust/split.rs,
// tools/scenes/split.steps and tools/scenes/listdetail.steps.

import Foundation

let DETAIL: UInt64 = 7

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    // The one adaptive declaration in the whole guest.
    tx.window(title: "split", listDetail: true)
    status = tx.signal(.str("list pane"))
    let root = tx.column {
        // Authored ids so the REAL-TREE read can address these: an
        // index read passes whether or not anything reached the
        // screen, which is the gap that let a non-rendering split arm
        // look green.
        tx.setA11yId(tx.label(bind: status), "list")  // label#0
        tx.button(
            "open detail",
            onClick: { inner in  // button#0
            // The popped handler rides the push, per-entry — the
            // onResult precedent, unchanged by the split.
            inner.pushEntry(
                DETAIL, title: "detail",
                // Retention: the base root took this write while the
                // detail was up, on a regular window where it was
                // VISIBLE the whole time.
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
