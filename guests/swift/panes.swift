// The panes scene, Swift port — guests/rust/panes.rs,
// tools/scenes/panes.steps.

import Foundation

let CONTENT: UInt64 = 7
let DETAIL: UInt64 = 8

let app = KayaApp()

app.build { tx in
    tx.window(title: "panes", panes: 3)
    let root = tx.column {
        // Authored ids: an index read passes for an arm that drew nothing.
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
