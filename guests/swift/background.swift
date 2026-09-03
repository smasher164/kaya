// The background scene, Swift port — guests/rust/background.rs,
// tools/scenes/background.steps.

import Foundation

let app = KayaApp()

let released = DispatchSemaphore(value: 0)
var posted = ""
var nested = ""

var status: KayaSignal!
var alive: KayaSignal!
var detail: KayaSignal!

app.build { tx in
    tx.window(title: "background")
    status = tx.signal(.str("idle"))
    alive = tx.signal(.str("-"))
    detail = tx.signal(.str("-"))
    let root = tx.column {
        tx.setA11yId(tx.label(bind: status), "status")  // label#0
        tx.setA11yId(tx.label(bind: alive), "alive")  // label#1
        tx.setA11yId(tx.label(bind: detail), "nested")  // label#2

        tx.button(
            "start",
            onClick: { inner in  // button#0
                Thread.detachNewThread {
                    released.wait()
                    for step in ["1", "2", "3"] {
                        app.post { tx in
                            posted += step
                            try tx.write(status, .str(posted))
                        }
                    }
                }
                try inner.write(status, .str("working"))
            })
        tx.button(
            "ping",
            onClick: { inner in  // button#1
                try inner.write(alive, .str("alive"))
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
                    try tx.write(detail, .str(nested))
                }
                nested += "c"
                try inner.write(detail, .str(nested))
            })
    }
    tx.mount(root)
}

app.run()
