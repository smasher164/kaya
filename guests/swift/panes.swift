// The panes conformance scene, Swift port — a THREE-pane ceiling as
// assertions (docs/multicolumn-plan.md D1/D5). Nothing here is
// panes-specific except `panes: 3`, asked for ONCE — the stack is the
// ordinary navigation stack, and how many of the three fit is the
// platform's re-decision at every width.
//
// See guests/rust/panes.rs and tools/scenes/panes.steps.

import Foundation

let CONTENT: UInt64 = 7
let DETAIL: UInt64 = 8

let app = KayaApp()

app.build { tx in
    tx.window(title: "panes", panes: 3)
    let root = tx.column {
        // Authored ids so the REAL-TREE read can address these: an index
        // read passes for an arm that ran and drew nothing.
        let caption = tx.signal(.str("root pane"))
        tx.setA11yId(tx.label(bind: caption), "root")  // label#0
        tx.button(
            "open content",
            onClick: { content in  // button#0
                content.pushEntry(CONTENT, title: "content")
                let pane = content.column {
                    let caption = content.signal(.str("content pane"))
                    content.setA11yId(content.label(bind: caption), "content")  // label#1
                    content.button(
                        "open detail",
                        onClick: { detail in  // button#1
                            detail.pushEntry(DETAIL, title: "detail")
                            let pane = detail.column {
                                let caption = detail.signal(.str("detail pane"))
                                // label#last
                                detail.setA11yId(detail.label(bind: caption), "detail")
                            }
                            detail.mountIn(DETAIL, pane)
                        })
                }
                content.mountIn(CONTENT, pane)
            })
    }
    tx.mount(root)
}

app.run()
