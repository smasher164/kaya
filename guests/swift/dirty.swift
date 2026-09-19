// The dirty scene, Swift port — guests/rust/dirty.rs,
// tools/scenes/dirty.steps.

import Foundation
import Kaya

KayaApp.run { app in
    app.build { tx in
        let doc = tx.signal(.str("notes"))
        let status = tx.signal(.str("saved"))
        tx.window(
            title: "dirty", vetoClose: true,
            onCloseRequested: { tx in
                tx.showAlert(
                    title: "unsaved changes",
                    message: "the document has unsaved changes",
                    actions: ["Discard"], cancel: "Keep Editing"
                ) { tx, choice in
                    if choice == .cancel {
                        // Answering a dialog is not saving: the mark stays up.
                        tx.write(status, .str("kept editing"))
                    } else {
                        // Aborts if it ever runs: an app can VETO a close but not
                        // AGREE to one (docs/traps.md).
                        tx.destroyWindow(0)
                    }
                }
            })

        let root = tx.column { root in
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
            return root
        }
        tx.mount(root)
    }
}
