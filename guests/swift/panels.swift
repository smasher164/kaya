// The panels conformance scene, Swift port — see guests/rust/panels.rs
// for the full rationale. A main window and an inspector; the
// inspector arms vetoClose, so the chrome close EMITS close_requested
// and closes nothing — the guest answers by recording the request in
// the status label and destroying the window (the request/confirm veto
// class, DESIGN.md's Presentation contexts). Desktop-only: phone hosts
// reject createWindow at the root by capability.
//
// The named arguments on createWindow are the Swift spelling of the
// window sugar; app.onCloseRequested is the event surface.

import Foundation

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    tx.window(title: "panels")
    status = tx.signal(.str("two panels"))
    let root = tx.column {
        tx.label(bind: status)  // label#0
    }
    tx.mount(root)

    // The veto handler binds to the inspector at its declaration
    // (handlers scope to the thing that creates them): it can only
    // ever mean this window's close.
    tx.createWindow(
        1, title: "inspector", width: 480.0, height: 320.0, vetoClose: true,
        onCloseRequested: { tx2 in
            tx2.write(status, .str("close requested"))
            tx2.destroyWindow(1)
        })
    let auxRoot = tx.column {
        let caption = tx.signal(.str("inspector pane"))
        tx.label(bind: caption)  // label#1
    }
    tx.mountIn(1, auxRoot)
}

app.run()
