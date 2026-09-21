// The sheet scene, Swift port — guests/rust/sheet.rs, tools/scenes/sheet.steps.

import Foundation
import Kaya

let TASK: UInt64 = 11
let DETAILS: UInt64 = 12

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "sheet")
        let status = tx.signal(.str("closed"))
        let draft = tx.signal(.str("draft: none"))
        func openTask(_ inner: KayaAppTx, armed: Bool) {
            // Nothing has gone when the request fires; the app keeps the
            // sheet up and says so.
            let onAsk: ((KayaAppTx) throws -> Void)? =
                armed ? { tx2 in tx2.write(status, .str("dismiss requested")) } : nil
            inner.presentSheet(
                TASK, title: "new task", interceptDismiss: armed, detent: .medium,
                onDismissed: { tx2 in tx2.write(status, .str("dismissed")) },
                onDismissRequested: onAsk)
            let body = inner.column { body in
                let caption = inner.signal(.str("what needs doing?"))
                inner.label(bind: caption)  // label#1
                _ = inner.entry { tx2, text in  // entry#0
                    tx2.write(draft, .str("draft: \(text)"))
                }
                inner.label(bind: draft)  // label#2
                inner.button(
                    "details",
                    onClick: { tx2 in  // button#2
                        tx2.presentSheet(
                            DETAILS, title: "details",
                            onDismissed: { tx3 in tx3.write(status, .str("details dismissed")) },
                            parent: TASK)
                        let pane = tx2.column { pane in
                            let caption = tx2.signal(.str("more about it"))
                            tx2.label(bind: caption)
                            return pane
                        }
                        tx2.mountIn(DETAILS, pane)
                        tx2.write(status, .str("details open"))
                    })
                inner.button(
                    "done",
                    onClick: { tx2 in  // button#3
                        // Programmatic: no sheet_dismissed follows, so "done" stays.
                        tx2.dismissSheet(TASK)
                        tx2.write(status, .str("done"))
                    })
                return body
            }
            inner.mountIn(TASK, body)
            inner.write(status, .str("open"))
            inner.write(draft, .str("draft: none"))
        }
        let root = tx.column { root in
            tx.label(bind: status)  // label#0
            tx.button("new task", onClick: { inner in openTask(inner, armed: false) })  // button#0
            tx.button("new task, armed", onClick: { inner in openTask(inner, armed: true) })  // button#1
            return root
        }
        tx.mount(root)
    }
}
