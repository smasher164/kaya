// The dirty-state conformance scene, Swift port — see guests/rust/dirty.rs
// and docs/dirty-plan.md. One boolean beside `title:` and `vetoClose:`;
// the backend spells its platform's own affordance, and the phones have
// none.
//
// TWO DECLARATIONS, ON PURPOSE. An edit writes the document AND says
// `dirty: true`; saving writes it back and says `dirty: false`. kaya
// does not watch your signals and guess.

import Foundation

let app = KayaApp()

var doc: KayaSignal!
var status: KayaSignal!

app.build { tx in
    // `dirty:` and `vetoClose:` are orthogonal — either can be set alone.
    tx.window(
        title: "dirty", vetoClose: true,
        onCloseRequested: { tx in
            // Nothing has closed: the veto class says so.
            tx.showAlert(
                title: "unsaved changes",
                message: "the document has unsaved changes",
                actions: ["Discard"], cancel: "Keep Editing"
            ) { tx, choice in
                if choice == KAYA_ALERT_CHOICE_CANCEL {
                    // Answering a dialog is not saving: the mark stays up.
                    tx.write(status, .str("kept editing"))
                } else {
                    // This ABORTS if it ever runs: an app can VETO a
                    // close but cannot AGREE to one (docs/traps.md).
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
            // ONE TRANSACTION, THREE STATEMENTS. Neither implies the other.
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
