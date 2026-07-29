// The background conformance scene, Swift port — work off the app
// thread, posted back (docs/background-work-plan.md).
//
// WHAT IT PROVES, and the reason for its odd shape: a wrong
// implementation must DEADLOCK rather than disagree. The worker parks
// until a CLICK releases it, and only a live app thread can process a
// click — so a binding that let background work occupy the app thread
// cannot reach the end of the script at all. It could not even deliver
// its own release.
//
// The parking is a plain DispatchSemaphore and the worker a detached
// Thread. kaya supplies no waiting primitive and should not: the point
// is that a guest uses its own language's concurrency and hands back
// only the result.
//
// The accumulators are the guest's own state rather than signal
// read-backs — signals are write-only by doctrine. They need no lock:
// everything that touches them runs on the app thread, inside a posted
// transaction.

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
        // Authored so the CLOSING read can address it: the AX read needs
        // an identifier, and an index read passes for an arm that ran
        // and drew nothing.
        tx.setA11yId(tx.label(bind: detail), "nested")  // label#2

        tx.button(
            "start",
            onClick: { inner in  // button#0
                Thread.detachNewThread {
                    // Parks here until the scene clicks release. Were
                    // the binding running this on the app thread, that
                    // click could never be processed and the whole scene
                    // would deadlock — the point.
                    released.wait()
                    // Three posts, in order. The accumulator makes this
                    // a test of ORDER and not merely of which one ran
                    // last.
                    for step in ["1", "2", "3"] {
                        app.post { tx in
                            posted += step
                            try tx.write(status, .str(posted))
                        }
                    }
                }
                try inner.write(status, .str("working"))
            })
        // Proof the app thread is still serving input while the worker
        // is parked and has posted nothing.
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
        // A post from INSIDE a handler QUEUES for after; it never nests.
        // The handler appends a, posts a closure appending b, appends c
        // — so it commits "ac" and the posted closure then commits
        // "acb". Nesting can only ever produce "abc".
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
