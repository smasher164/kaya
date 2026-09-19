// The background scene, Swift port — guests/rust/background.rs,
// tools/scenes/background.steps.

import Foundation
import Kaya

KayaApp.run { app in
    let post = app.post
    let released = DispatchSemaphore(value: 0)
    var posted = ""
    var nested = ""

    app.build { tx in
        tx.window(title: "background")
        let status = tx.signal(.str("idle"))
        let alive = tx.signal(.str("-"))
        let detail = tx.signal(.str("-"))
        let root = tx.column { root in
            tx.setA11yId(tx.label(bind: status), "status")  // label#0
            tx.setA11yId(tx.label(bind: alive), "alive")  // label#1
            tx.setA11yId(tx.label(bind: detail), "nested")  // label#2

            tx.button(
            "start",
            onClick: { inner in  // button#0
                let receive: @KayaAppActor @Sendable (KayaAppTx, String) -> Void = { tx, step in
                    posted += step
                    tx.write(status, .str(posted))
                }
                Thread.detachNewThread {
                        released.wait()
                        for step in ["1", "2", "3"] {
                            post { tx in
                            receive(tx, step)
                            }
                        }
                    }
                    inner.write(status, .str("working"))
                })
            tx.button(
                "ping",
                onClick: { inner in  // button#1
                    inner.write(alive, .str("alive"))
                })
            tx.button(
                "release",
                onClick: { _ in  // button#2
                    released.signal()
                })
            tx.button(
                "nest",
                onClick: { inner in  // button#3
                    nested += "a"
                    app.post { tx in
                        nested += "b"
                        tx.write(detail, .str(nested))
                    }
                    nested += "c"
                    inner.write(detail, .str(nested))
                })
            return root
        }
        tx.mount(root)
    }
}
