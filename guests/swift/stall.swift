// The stall conformance scene, Swift port — an app thread that stops
// taking its occurrences is REPORTED (DESIGN.md, Threading model and
// protocol). See guests/rust/stall.rs and tools/scenes/stall.steps.
//
// THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, in every language:
// `block` sleeps on the app thread and the scene asserts kaya NOTICES.
// The class is not hypothetical — docs/deferred.md records a Haskell
// release whose blocking put would have wedged the app thread forever.
//
// WHY THE SECOND CLICK MATTERS: the consumer cursor advances BEFORE a
// record reaches the guest, so a handler blocking on an empty queue
// looks exactly like an idle app. `ping` is what makes work PENDING
// while the app thread is gone.
//
// `wedge` never returns, which is the shape a real deadlock has; the leg
// still reports its verdict, because the harness runs on its own thread
// and asks the MAIN thread to exit.

import Foundation

// Comfortably past the watchdog's one-second threshold.
let blockSeconds = 2.5

// A day, never a literal park (docs/traps.md, "The stall scene wedges
// for a DAY").
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
