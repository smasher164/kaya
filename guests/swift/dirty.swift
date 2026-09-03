// The dirty scene, Swift port — guests/rust/dirty.rs,
// tools/scenes/dirty.steps.

import Foundation

let app = KayaApp()

var doc: KayaSignal!
var status: KayaSignal!

app.build { tx in
    tx.window(
        title: "dirty", vetoClose: true,
        onCloseRequested: { tx in
            tx.showAlert(
                title: "unsaved changes",
                message: "the document has unsaved changes",
                actions: ["Discard"], cancel: "Keep Editing"
            ) { tx, choice in
                if choice == KAYA_ALERT_CHOICE_CANCEL {
                    // Answering a dialog is not saving: the mark stays up.
                    tx.write(status, .str("kept editing"))
                } else {
                    // Aborts if it ever runs: an app can VETO a close but not
                    // AGREE to one (docs/traps.md).
                    tx.destroyWindow(0)
                }
            }
        })

    doc = tx.signal(.str("notes"))
    status = tx.signal(.str("saved"))
    let root = tx.column {
        tx.label(bind: doc)  // label#0
        tx.label(bind: status)  // label#1
        tx.button("edit") { tx in  // button#0
            tx.write(doc, .str("notes and a line"))
            tx.write(status, .str("unsaved"))
            tx.window(dirty: true)
        }
        tx.button("save") { tx in  // button#1
            tx.write(status, .str("saved"))
            // The mark comes DOWN as well as up.
            tx.window(dirty: false)
        }
    }
    tx.mount(root)
}

app.run()
